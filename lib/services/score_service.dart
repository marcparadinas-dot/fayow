import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ScoreService {
  static final _db = FirebaseFirestore.instance;

  // -------------------------------------------------------------------------
  // Points par action
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
  // Mises à jour incrémentales
  // -------------------------------------------------------------------------

  /// Appelé quand un POI validé est lu
  static Future<void> incrementerPoisLus(String uid) async {
    try {
      await _db.collection('users').doc(uid).update({
        'score.poisLus': FieldValue.increment(1),
        'score.total':   FieldValue.increment(pointsPoiLu),
      });
    } catch (e) {
      print('Erreur incrementerPoisLus : $e');
    }
  }

  /// Appelé quand un POI passe à un nouveau statut
  /// [ancienStatut] peut être null si c'est une création
  static Future<void> mettreAJourStatutPoi(
    String uid, {
    String? ancienStatut,
    required String nouveauStatut,
  }) async {
    try {
      final Map<String, dynamic> updates = {};

      // Retirer les points de l'ancien statut
      if (ancienStatut != null) {
        switch (ancienStatut) {
          case 'initiated':
            updates['score.poisInitiated'] = FieldValue.increment(-1);
            updates['score.total'] = FieldValue.increment(-pointsPoiInitiated);
            break;
          case 'proposed':
            updates['score.poisProposed'] = FieldValue.increment(-1);
            updates['score.total'] = FieldValue.increment(-pointsPoiProposed);
            break;
          case 'validated':
            updates['score.poisValidated'] = FieldValue.increment(-1);
            updates['score.total'] = FieldValue.increment(-pointsPoiValidated);
            break;
        }
      }

      // Ajouter les points du nouveau statut
      switch (nouveauStatut) {
        case 'initiated':
          updates['score.poisInitiated'] = FieldValue.increment(1);
          updates['score.total'] = FieldValue.increment(pointsPoiInitiated);
          break;
        case 'proposed':
          updates['score.poisProposed'] = FieldValue.increment(1);
          updates['score.total'] = FieldValue.increment(pointsPoiProposed);
          break;
        case 'validated':
          updates['score.poisValidated'] = FieldValue.increment(1);
          updates['score.total'] = FieldValue.increment(pointsPoiValidated);
          break;
      }

      if (updates.isNotEmpty) {
        await _db.collection('users').doc(uid).update(updates);
      }
    } catch (e) {
      print('Erreur mettreAJourStatutPoi : $e');
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