const { setGlobalOptions } = require("firebase-functions");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const {
  onDocumentWritten,
  onDocumentCreated,
} = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");

// Pour limiter les coûts en cas de pic de trafic inattendu (par fonction,
// surchageable individuellement avec l'option maxInstances).
setGlobalOptions({ maxInstances: 10 });

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

const MODERATOR_EMAILS = [
  "marc.paradinas@gmail.com",
  "marc.paradinas@wanadoo.fr",
];

// Collection surveillée par l'extension Firebase "Trigger Email from Firestore".
const COLLECTION_MAIL = "mail";

// ---------------------------------------------------------------------------
// Barème de points — garder en phase avec ScoreService côté Flutter si tu
// changes un jour ces valeurs.
// ---------------------------------------------------------------------------
const POINTS = {
  lu: 1,
  initiated: 2,
  proposed: 5,
  validated: 10,
};

// Statut Firestore -> nom du compteur dans score.*
const STATUS_TO_FIELD = {
  initiated: "poisInitiated",
  proposed: "poisProposed",
  validated: "poisValidated",
};

function pointsPourStatut(status) {
  return POINTS[status] || 0;
}

// ---------------------------------------------------------------------------
// Un utilisateur avec masquerDuClassement: true dans son document users/{uid}
// n'apparaît plus dans le classement — géré simplement en ne mettant jamais
// à jour son champ score.total, dont l'absence exclut automatiquement le
// document des résultats de chargerClassement() (orderBy('score.total')).
// Les autres compteurs (poisLus, poisInitiated, etc.) continuent d'être mis
// à jour normalement, pour ne rien perdre si le compte est démasqué plus
// tard (il suffira alors d'appeler recalculerScore côté Flutter, ou de
// remettre le champ total à la main, pour qu'il réapparaisse).
// ---------------------------------------------------------------------------
async function estMasqueDuClassement(uid) {
  try {
    const doc = await db.collection("users").doc(uid).get();
    return doc.exists && doc.data().masquerDuClassement === true;
  } catch (error) {
    console.error(`Erreur lecture masquerDuClassement pour ${uid} :`, error.message);
    return false; // en cas de doute, on ne masque pas.
  }
}

function echapperHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

// =============================================================================
// deleteUserAccount
// =============================================================================
exports.deleteUserAccount = onCall(
  { region: "us-central1" },
  async (request) => {
    // Vérifier que la personne est bien connectée
    if (!request.auth) {
      throw new HttpsError(
        "unauthenticated",
        "Vous devez être connecté pour supprimer votre compte."
      );
    }

    const uid = request.auth.uid;
    const targetUid = request.data.targetUid;

    // Sécurité : on ne permet de supprimer que son propre compte
    if (uid !== targetUid) {
      throw new HttpsError(
        "permission-denied",
        "Vous ne pouvez supprimer que votre propre compte."
      );
    }

    try {
      // 1. Récupérer le pseudo pour libérer son entrée dans /pseudos
      const userDoc = await db.collection("users").doc(uid).get();
      const pseudo = userDoc.data() && userDoc.data().pseudo;

      // 2. Supprimer la sous-collection readPois
      const readPoisSnap = await db
        .collection("users")
        .doc(uid)
        .collection("readPois")
        .get();
      const batch = db.batch();
      readPoisSnap.docs.forEach((doc) => batch.delete(doc.ref));

      // 3. Supprimer le document utilisateur principal
      batch.delete(db.collection("users").doc(uid));

      // 4. Libérer le pseudo réservé, s'il existe
      if (pseudo) {
        const pseudoKey = pseudo.toLowerCase();
        batch.delete(db.collection("pseudos").doc(pseudoKey));
      }

      await batch.commit();

      // 5. Supprimer le compte Firebase Auth lui-même
      await admin.auth().deleteUser(uid);

      return { success: true };
    } catch (error) {
      console.error("Erreur suppression compte:", error);
      throw new HttpsError(
        "internal",
        "Erreur lors de la suppression du compte : " + error.message
      );
    }
  }
);

// =============================================================================
// updateUserEmail
// =============================================================================
exports.updateUserEmail = onCall(
  { region: "us-central1" },
  async (request) => {
    // Log de debug
    console.log("request.auth:", JSON.stringify(request.auth));
    console.log("request.data:", JSON.stringify(request.data));

    if (!request.auth) {
      console.log("PAS D'AUTH !");
      throw new HttpsError(
        "unauthenticated",
        "L'utilisateur doit être connecté."
      );
    }

    const { targetUid, newEmail } = request.data;

    if (!targetUid || typeof targetUid !== "string") {
      throw new HttpsError("invalid-argument", "targetUid manquant.");
    }
    if (!newEmail || typeof newEmail !== "string" || !newEmail.includes("@")) {
      throw new HttpsError("invalid-argument", "newEmail invalide.");
    }

    const appelantUid = request.auth.uid;
    const estModerateur = MODERATOR_EMAILS.includes(request.auth.token.email);
    const estSonPropriCompte = appelantUid === targetUid;

    if (!estSonPropriCompte && !estModerateur) {
      throw new HttpsError(
        "permission-denied",
        "Vous ne pouvez modifier que votre propre email."
      );
    }

    try {
      await admin.auth().updateUser(targetUid, {
        email: newEmail,
        emailVerified: false,
      });

      return { success: true, message: `Email mis à jour vers ${newEmail}.` };
    } catch (error) {
      if (error.code === "auth/email-already-in-use") {
        throw new HttpsError("already-exists", "Cet email est déjà utilisé.");
      }
      if (error.code === "auth/user-not-found") {
        throw new HttpsError("not-found", "Utilisateur introuvable.");
      }
      throw new HttpsError("internal", "Erreur interne.", error.message);
    }
  }
);

// =============================================================================
// recalculerScoreSurChangementStatut
//
// Se déclenche sur toute écriture d'un document pois/{poiId} : création,
// changement de statut, ou suppression — peu importe si l'écriture vient de
// l'appli Flutter ou de l'interface modérateur, puisque c'est Firestore
// lui-même qui est observé.
// =============================================================================
exports.recalculerScoreSurChangementStatut = onDocumentWritten(
  { document: "pois/{poiId}", region: "us-central1" },
  async (event) => {
    const beforeSnap = event.data.before;
    const afterSnap = event.data.after;

    const beforeData = beforeSnap && beforeSnap.exists ? beforeSnap.data() : null;
    const afterData = afterSnap && afterSnap.exists ? afterSnap.data() : null;

    const creatorUid =
      (afterData && afterData.creatorUid) ||
      (beforeData && beforeData.creatorUid);

    if (!creatorUid) {
      console.log("Pas de creatorUid trouvé, on ignore.");
      return;
    }

    const beforeStatus = beforeData && beforeData.status;
    const afterStatus = afterData && afterData.status;

    if (beforeStatus === afterStatus) {
      // Rien à faire pour le score (autre champ modifié, ou pas de statut).
      return;
    }

    const updates = {};
    let deltaTotal = 0;

    if (beforeStatus && STATUS_TO_FIELD[beforeStatus]) {
      updates[`score.${STATUS_TO_FIELD[beforeStatus]}`] =
        admin.firestore.FieldValue.increment(-1);
      deltaTotal -= pointsPourStatut(beforeStatus);
    }

    if (afterStatus && STATUS_TO_FIELD[afterStatus]) {
      updates[`score.${STATUS_TO_FIELD[afterStatus]}`] =
        admin.firestore.FieldValue.increment(1);
      deltaTotal += pointsPourStatut(afterStatus);
    }

    const masque = await estMasqueDuClassement(creatorUid);
    if (deltaTotal !== 0 && !masque) {
      updates["score.total"] = admin.firestore.FieldValue.increment(deltaTotal);
    }

    if (Object.keys(updates).length === 0) {
      return;
    }

    try {
      await db.collection("users").doc(creatorUid).update(updates);
      console.log(
        `Score mis à jour pour ${creatorUid} : ${beforeStatus || "(aucun)"} → ${
          afterStatus || "(aucun)"
        } (Δtotal=${masque ? "ignoré (masqué)" : deltaTotal})`
      );
    } catch (error) {
      console.error(
        `Erreur mise à jour score pour ${creatorUid} :`,
        error.message
      );
    }
  }
);

// =============================================================================
// recalculerScoreSurLecture
//
// Se déclenche à la création d'un document dans users/{uid}/readPois —
// c'est-à-dire quand un utilisateur lit une anecdote.
// =============================================================================
exports.recalculerScoreSurLecture = onDocumentCreated(
  { document: "users/{uid}/readPois/{poiId}", region: "us-central1" },
  async (event) => {
    const uid = event.params.uid;

    const updates = {
      "score.poisLus": admin.firestore.FieldValue.increment(1),
    };

    const masque = await estMasqueDuClassement(uid);
    if (!masque) {
      updates["score.total"] = admin.firestore.FieldValue.increment(POINTS.lu);
    }

    try {
      await db.collection("users").doc(uid).update(updates);
      console.log(
        `+${POINTS.lu} pt (lecture) pour ${uid}${masque ? " — total ignoré (masqué)" : ""}`
      );
    } catch (error) {
      console.error(`Erreur incrément lecture pour ${uid} :`, error.message);
    }
  }
);

// =============================================================================
// notifierValidationAnecdote
//
// À la transition d'une anecdote vers le statut "validated", dépose un e-mail
// de remerciement dans la collection "mail" (envoyé par l'extension Firebase
// "Trigger Email from Firestore"). Uniquement pour les utilisateurs qui
// disposent d'un score.total (donc jamais pour les comptes masqués).
// =============================================================================
exports.notifierValidationAnecdote = onDocumentWritten(
  { document: "pois/{poiId}", region: "us-central1" },
  async (event) => {
    const beforeSnap = event.data.before;
    const afterSnap = event.data.after;

    const beforeData = beforeSnap && beforeSnap.exists ? beforeSnap.data() : null;
    const afterData = afterSnap && afterSnap.exists ? afterSnap.data() : null;

    if (!afterData) return; // suppression

    const beforeStatus = beforeData && beforeData.status;
    const afterStatus = afterData.status;

    // Uniquement à la transition vers "validated"
    if (afterStatus !== "validated" || beforeStatus === "validated") return;

    const creatorUid = afterData.creatorUid;
    if (!creatorUid) return;

    try {
      const userSnap = await db.collection("users").doc(creatorUid).get();
      if (!userSnap.exists) return;
      const user = userSnap.data();

      // Uniquement les utilisateurs disposant d'un total de score
      if (user.masquerDuClassement === true) return;
      if (typeof (user.score && user.score.total) !== "number") return;

      const userRecord = await admin.auth().getUser(creatorUid);
      const email = userRecord.email;
      if (!email) return;

      const pseudo = user.pseudo || "contributeur";

      const lat = Number(afterData.lat);
      const lng = Number(afterData.lng);
      const coords =
        Number.isFinite(lat) && Number.isFinite(lng)
          ? `${lat.toFixed(4)}, ${lng.toFixed(4)}`
          : "indiquées";

      // Points gagnés = valeur "validé" moins celle du statut précédent
      const gain = POINTS.validated - pointsPourStatut(beforeStatus);

      const sujet = "FaYoW - Votre anecdote est validée !";

      const texte =
`Bonjour ${pseudo},

L'anecdote que vous avez proposée aux coordonnées ${coords} a été acceptée ! Elle est désormais disponible pour l'ensemble des utilisateurs de FaYoW.

Bravo, votre score a gagné ${gain} points supplémentaires !
Et merci infiniment de contribuer à enchanter le monde.

Nota : De légères modifications de forme ont pu être apportées par la modération (position, orthographe, grammaire, suppression de caractères non interprétés par la synthèse vocale), mais le fond de l'anecdote a été préservé.`;

      const html =
`<p>Bonjour ${echapperHtml(pseudo)},</p>
<p>L'anecdote que vous avez proposée aux coordonnées ${echapperHtml(coords)} a été acceptée ! Elle est désormais disponible pour l'ensemble des utilisateurs de FaYoW.</p>
<p>Bravo, votre score a gagné ${gain} points supplémentaires !<br>
Et merci infiniment de contribuer à enchanter le monde.</p>
<p><em>Nota : De légères modifications de forme ont pu être apportées par la modération (position, orthographe, grammaire, suppression de caractères non interprétés par la synthèse vocale), mais le fond de l'anecdote a été préservé.</em></p>`;

      // ID déterministe : évite un doublon si le trigger est rejoué
      await db
        .collection(COLLECTION_MAIL)
        .doc(`validation_${event.params.poiId}`)
        .set({
          to: email,
          message: { subject: sujet, text: texte, html: html },
        });

      console.log(`Mail de validation déposé pour ${creatorUid} (${event.params.poiId}).`);
    } catch (error) {
      console.error(
        `Erreur notification de validation pour ${creatorUid} :`,
        error.message
      );
    }
  }
);