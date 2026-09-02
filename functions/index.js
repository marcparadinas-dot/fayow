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
//
// Logique unifiée : on retire les points de l'ancien statut (s'il y en avait
// un et qu'il a changé) et on ajoute ceux du nouveau (s'il y en a un et qu'il
// a changé), en un seul delta calculé côté serveur — ce qui évite le bug
// d'écrasement qu'on avait côté Dart.
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

    if (deltaTotal !== 0) {
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
        } (Δtotal=${deltaTotal})`
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

    try {
      await db.collection("users").doc(uid).update({
        "score.poisLus": admin.firestore.FieldValue.increment(1),
        "score.total": admin.firestore.FieldValue.increment(POINTS.lu),
      });
      console.log(`+${POINTS.lu} pt (lecture) pour ${uid}`);
    } catch (error) {
      console.error(`Erreur incrément lecture pour ${uid} :`, error.message);
    }
  }
);