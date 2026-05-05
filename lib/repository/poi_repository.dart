import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/poi_models.dart';

class PoiRepository {
  final _db = FirebaseFirestore.instance;

  // Charger les POIs validés (visibles par tous)
Future<List<PointInteret>> chargerPoisValides() async {
  try {
    final snapshot = await _db
        .collection('pois')
        .where('status', isEqualTo: 'validated')
        .get();
    return snapshot.docs
        .map((doc) => PointInteret.fromFirestore(doc.id, doc.data()))
        .toList();
  } catch (e) {
    print('Erreur chargerPoisValides : $e');
    return [];
  }
}

Future<List<PointInteret>> chargerMesPois(String uid) async {
  try {
    final snapshot = await _db
        .collection('pois')
        .where('creatorUid', isEqualTo: uid)
        .where('status', whereIn: ['initiated', 'proposed'])
        .get();
    return snapshot.docs
        .map((doc) => PointInteret.fromFirestore(doc.id, doc.data()))
        .toList();
  } catch (e) {
    print('Erreur chargerMesPois : $e');
    return [];
  }
}

  // Charger les POIs lus par l'utilisateur
Future<Set<String>> chargerPoisLus(String uid) async {
  try {
    final snapshot = await _db
        .collection('users')
        .doc(uid)
        .collection('readPois') // ← était 'poisLus'
        .get();
    return snapshot.docs.map((doc) => doc.id).toSet();
  } catch (e) {
    print('Erreur chargerPoisLus : $e');
    return {};
  }
}

// Charger tous les POIs proposés (pour le modérateur)
Future<List<PointInteret>> chargerTousPoisProposed() async {
  try {
    final snapshot = await _db
        .collection('pois')
        .where('status', isEqualTo: 'proposed')
        .get();
    return snapshot.docs
        .map((doc) => PointInteret.fromFirestore(doc.id, doc.data()))
        .toList();
  } catch (e) {
    print('Erreur chargerTousPoisProposed : $e');
    return [];
  }
}

  // Mettre à jour un POI
  Future<void> mettreAJourPoi(
      String poiId, Map<String, dynamic> data) async {
    await _db.collection('pois').doc(poiId).update(data);
  }

  // Ajouter un POI
  Future<void> ajouterPoi({
    required double latitude,
    required double longitude,
    required String message,
    required String creatorUid,
  }) async {
    await _db.collection('pois').add({
      'lat': latitude,
      'lng': longitude,
      'message': message,
      'creatorUid': creatorUid,
      'status': 'initiated',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}