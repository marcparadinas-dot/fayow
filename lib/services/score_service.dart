import 'package:cloud_firestore/cloud_firestore.dart';

class ScoreService {
  static final _db = FirebaseFirestore.instance;

  // -------------------------------------------------------------------------
  // Points par action
  //
  // NB : le calcul incrémental du score (à la lecture d'une anecdote, ou au
  // changement de statut d'un POI) est désormais géré côté serveur par les
  // Cloud Functions recalculerScoreSurLecture et
  // recalculerScoreSurChangementStatut (voir functions/index.js), qui se
  // déclenchent automatiquement sur l'écriture Firestore correspondante —
  // que ce soit depuis l'appli ou depuis l'interface modérateur. Ces
  // constantes ne servent donc plus qu'à recalculerScore() ci-dessous.
  // -------------------------------------------------------------------------
  static const int pointsPoiLu       = 1;
  static const int pointsPoiInitiated = 2;
  static const int pointsPoiProposed  = 5;
  static const int pointsPoiValidated = 10;

  // -------------------------------------------------------------------------
  // Recalcul complet du score (appelé une seule fois au premier lancement)
  // -------------------------------------------------------------------------

  static Future<void> initialiserScoreSiNecessaire(String uid) async {
    try {
      final userDoc = await _db.collection('users').doc(uid).get();
      final data = userDoc.data();

      // Si le score est déjà initialisé, ne rien faire
      if (data != null && data.containsKey('scoreInitialise') &&
          data['scoreInitialise'] == true) {
        return;
      }

      print('ScoreService : initialisation du score pour $uid');
      await recalculerScore(uid);

      // Marquer comme initialisé
      await _db.collection('users').doc(uid).update({
        'scoreInitialise': true,
      });
    } catch (e) {
      print('Erreur initialisation score : $e');
    }
  }

  // -------------------------------------------------------------------------
  // Recalcul complet depuis Firestore (pour le passé et les corrections)
  //
  // Reste utile comme filet de sécurité ponctuel (ex. après une migration
  // de données), même si les Cloud Functions maintiennent normalement le
  // score à jour en continu.
  // -------------------------------------------------------------------------

  static Future<void> recalculerScore(String uid) async {
    try {
      // Compter les POIs lus
      final poisLusSnap = await _db
          .collection('users')
          .doc(uid)
          .collection('readPois')
          .get();
      final poisLus = poisLusSnap.docs.length;

      // Compter les POIs par statut
      final mesPoisSnap = await _db
          .collection('pois')
          .where('creatorUid', isEqualTo: uid)
          .get();

      final poisInitiated = mesPoisSnap.docs
          .where((d) => d.data()['status'] == 'initiated')
          .length;
      final poisProposed = mesPoisSnap.docs
          .where((d) => d.data()['status'] == 'proposed')
          .length;
      final poisValidated = mesPoisSnap.docs
          .where((d) => d.data()['status'] == 'validated')
          .length;

      final total = (poisLus * pointsPoiLu) +
          (poisInitiated * pointsPoiInitiated) +
          (poisProposed * pointsPoiProposed) +
          (poisValidated * pointsPoiValidated);

      await _db.collection('users').doc(uid).update({
        'score': {
          'poisLus':       poisLus,
          'poisInitiated': poisInitiated,
          'poisProposed':  poisProposed,
          'poisValidated': poisValidated,
          'total':         total,
        },
      });

      print('ScoreService : score recalculé pour $uid → $total points');
    } catch (e) {
      print('Erreur recalcul score : $e');
    }
  }

  // -------------------------------------------------------------------------
  // Lecture du classement
  // -------------------------------------------------------------------------

  static Future<List<Map<String, dynamic>>> chargerClassement() async {
    try {
      final snap = await _db
          .collection('users')
          .orderBy('score.total', descending: true)
          .get();

      return snap.docs.map((doc) {
        final data = doc.data();
        final score = data['score'] as Map<String, dynamic>? ?? {};
        return {
          'uid':    doc.id,
          'pseudo': data['pseudo'] ?? 'Anonyme',
          'total':  score['total'] ?? 0,
          'poisLus':       score['poisLus'] ?? 0,
          'poisInitiated': score['poisInitiated'] ?? 0,
          'poisProposed':  score['poisProposed'] ?? 0,
          'poisValidated': score['poisValidated'] ?? 0,
        };
      }).toList();
    } catch (e) {
      print('Erreur chargement classement : $e');
      return [];
    }
  }
}