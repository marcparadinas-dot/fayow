/**
 * Import function triggers from their respective submodules:
 *
 * const {onCall} = require("firebase-functions/v2/https");
 * const {onDocumentWritten} = require("firebase-functions/v2/firestore");
 *
 * See a full list of supported triggers at https://firebase.google.com/docs/functions
 */

const {setGlobalOptions} = require("firebase-functions");
const {onRequest} = require("firebase-functions/https");
const logger = require("firebase-functions/logger");

// For cost control, you can set the maximum number of containers that can be
// running at the same time. This helps mitigate the impact of unexpected
// traffic spikes by instead downgrading performance. This limit is a
// per-function limit. You can override the limit for each function using the
// `maxInstances` option in the function's options, e.g.
// `onRequest({ maxInstances: 5 }, (req, res) => { ... })`.
// NOTE: setGlobalOptions does not apply to functions using the v1 API. V1
// functions should each use functions.runWith({ maxInstances: 10 }) instead.
// In the v1 API, each function can only serve one request per container, so
// this will be the maximum concurrent request count.
setGlobalOptions({ maxInstances: 10 });

// Create and deploy your first functions
// https://firebase.google.com/docs/functions/get-started

// exports.helloWorld = onRequest((request, response) => {
//   logger.info("Hello logs!", {structuredData: true});
//   response.send("Hello from Firebase!");
// });
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

if (!admin.apps.length) {
  admin.initializeApp();
}

exports.deleteUserAccount = onCall(
  {region: "us-central1"},
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

    const db = admin.firestore();

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

      return {success: true};
    } catch (error) {
      console.error("Erreur suppression compte:", error);
      throw new HttpsError(
        "internal",
        "Erreur lors de la suppression du compte : " + error.message
      );
    }
  }
);