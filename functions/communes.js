"use strict";

// Enrichit chaque POI avec sa commune, son département, sa région et son pays
// (champs `commune`, `departement`, `region`, `pays`), via Nominatim reverse.
// La logique de choix du nom de commune est la même que dans
// commune_service.dart (city > town > village > municipality), pour que
// l'annonce vocale et l'écran « Communes FaYoW » parlent de la même commune.
//
// Fonctions de 2e génération (comme celles de index.js), Node 18+ requis
// (fetch et AbortSignal.timeout natifs).
//
// Dans index.js :
//   Object.assign(exports, require("./communes"));

const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");

if (!admin.apps.length) admin.initializeApp();
const db = admin.firestore();

// Nominatim demande un User-Agent qui identifie l'application ET un contact.
const USER_AGENT = "FayowApp/1.0 (marc.paradinas@gmail.com)";

/**
 * Interroge Nominatim reverse. Renvoie { infos, statut } :
 * - infos : { commune, departement, region, pays }, ou null en cas d'échec ;
 * - statut : code HTTP de la réponse (0 si erreur réseau ou délai dépassé).
 * Rien n'est écrit en cas d'échec : on pourra réessayer plus tard.
 */
async function identifierCommune(lat, lng) {
  const url =
    "https://nominatim.openstreetmap.org/reverse" +
    `?lat=${lat}&lon=${lng}&format=json&addressdetails=1&accept-language=fr`;
  try {
    const reponse = await fetch(url, {
      headers: { "User-Agent": USER_AGENT },
      signal: AbortSignal.timeout(8000),
    });
    if (!reponse.ok) {
      console.error(`Nominatim : HTTP ${reponse.status}`);
      return { infos: null, statut: reponse.status };
    }
    const data = await reponse.json();
    const a = data.address;
    if (!a) return { infos: null, statut: reponse.status };
    return {
      infos: {
        commune: a.city || a.town || a.village || a.municipality || "",
        departement: a.county || "",
        region: a.state || a.region || "",
        pays: a.country || "",
      },
      statut: reponse.status,
    };
  } catch (e) {
    console.error("Erreur Nominatim reverse :", e.message);
    return { infos: null, statut: 0 };
  }
}

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * À chaque écriture d'un POI : calcule la localisation administrative si elle
 * manque, ou si le POI a été déplacé. L'écriture déclenche à nouveau ce
 * trigger, mais il s'arrête aussitôt (champ présent et position inchangée).
 */
exports.enrichirCommunePoi = onDocumentWritten(
  { document: "pois/{poiId}", region: "us-central1", timeoutSeconds: 60 },
  async (event) => {
    const afterSnap = event.data.after;
    const beforeSnap = event.data.before;
    if (!afterSnap || !afterSnap.exists) return;

    const apres = afterSnap.data();
    const avant = beforeSnap && beforeSnap.exists ? beforeSnap.data() : null;
    const { lat, lng } = apres;
    if (typeof lat !== "number" || typeof lng !== "number") return;

    const dejaRenseigne = apres.commune !== undefined;
    const aBouge = avant !== null && (avant.lat !== lat || avant.lng !== lng);
    if (dejaRenseigne && !aBouge) return;

    const { infos } = await identifierCommune(lat, lng);
    if (!infos) return;
    await afterSnap.ref.update(infos);
  }
);

/**
 * Rattrapage des POIs existants (sans champ `commune`).
 * Se déclenche en créant ou en modifiant le document taches/backfillCommunes
 * depuis la console Firestore. Traite au plus `limite` POIs par lancement
 * (300 par défaut, 400 max) à raison d'une requête Nominatim par seconde,
 * puis écrit le bilan dans taches/backfillCommunesResultat.
 *
 * Le lot s'arrête de lui-même si Nominatim refuse les requêtes (HTTP 429 ou
 * 403) ou après 5 échecs consécutifs, pour ne pas insister inutilement ; la
 * raison est alors indiquée dans le champ `arret` du bilan.
 */
exports.backfillCommunesPois = onDocumentWritten(
  {
    document: "taches/backfillCommunes",
    region: "us-central1",
    timeoutSeconds: 540,
  },
  async (event) => {
    const afterSnap = event.data.after;
    if (!afterSnap || !afterSnap.exists) return;

    const debut = Date.now();
    const limite = Math.min(Number(afterSnap.data().limite) || 300, 400);

    // Visible tout de suite dans la console : prouve que le lot a démarré.
    // Si "en cours" ne passe jamais à "terminé", la fonction a été interrompue
    // (voir les journaux).
    await db.doc("taches/backfillCommunesResultat").set(
      {
        etat: "en cours",
        debutLot: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    const snap = await db.collection("pois").get();
    const aTraiter = snap.docs.filter((d) => d.data().commune === undefined);

    let traites = 0;
    let echecs = 0;
    let echecsConsecutifs = 0;
    let dernierStatutHttp = null;
    let arret = null;

    for (const doc of aTraiter.slice(0, limite)) {
      // Budget de temps : on s'arrête proprement avant les 540 s, pour que le
      // bilan soit toujours écrit (sinon la fonction est tuée sans bilan).
      if (Date.now() - debut > 480000) {
        arret = "Temps limite du lot atteint (480 s) : relancer pour la suite";
        break;
      }
      const { lat, lng } = doc.data();
      if (typeof lat !== "number" || typeof lng !== "number") {
        echecs++;
        continue;
      }

      const { infos, statut } = await identifierCommune(lat, lng);
      if (infos) {
        await doc.ref.update(infos);
        traites++;
        echecsConsecutifs = 0;
      } else {
        echecs++;
        echecsConsecutifs++;
        dernierStatutHttp = statut;
        if (statut === 429 || statut === 403 || echecsConsecutifs >= 5) {
          arret =
            `Arrêt après ${echecsConsecutifs} échec(s) consécutif(s), ` +
            `dernier statut HTTP : ${statut}`;
          break;
        }
      }
      await pause(1100); // politique d'usage de Nominatim : 1 requête/s max
    }

    await db.doc("taches/backfillCommunesResultat").set({
      etat: "terminé",
      traites,
      echecs,
      restants: aTraiter.length - traites,
      arret,
      dernierStatutHttp,
      date: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
);