import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';
import '../models/poi_models.dart';

class CommuneService {
  // -------------------------------------------------------------------------
  // État
  // -------------------------------------------------------------------------

  String? _communeActuelle;
  List<List<double>>? _polygoneActuel;
  DateTime? _derniereAnnonce;

  // Temporisation : 10 minutes entre deux annonces
  static const Duration _tempoMin = Duration(minutes: 10);

  // TTS dédié aux annonces de commune (voix distincte)
  final FlutterTts _tts = FlutterTts();
  bool _ttsReady = false;

  // -------------------------------------------------------------------------
  // Initialisation
  // -------------------------------------------------------------------------

  Future<void> initialiser() async {
    await _tts.setLanguage('fr-FR');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);

    // Essayer une voix féminine pour distinguer des annonces POI
    final voices = await _tts.getVoices as List?;
    if (voices != null) {
      final voixFeminine = voices.cast<Map>().firstWhere(
        (v) =>
            (v['locale'] as String?)?.startsWith('fr') == true &&
            ((v['name'] as String?)?.toLowerCase().contains('female') == true ||
                (v['name'] as String?)?.toLowerCase().contains('frf') == true),
        orElse: () => <String, String>{},
      );
      if (voixFeminine.isNotEmpty && voixFeminine['name'] != null) {
        await _tts.setVoice({'name': voixFeminine['name'], 'locale': 'fr-FR'});
      }
    }

    _ttsReady = true;
  }

  void dispose() {
    _tts.stop();
  }

  void reinitialiser() {
    _communeActuelle = null;
    _polygoneActuel = null;
    _derniereAnnonce = null;
  }

  // -------------------------------------------------------------------------
  // Point d'entrée principal
  // -------------------------------------------------------------------------

  Future<void> verifierCommune({
    required double latitude,
    required double longitude,
    required List<PointInteret> pointsInteret,
    required Set<String> poisLusIds,
  }) async {
    // Vérifier la temporisation
    if (_derniereAnnonce != null) {
      final elapsed = DateTime.now().difference(_derniereAnnonce!);
      if (elapsed < _tempoMin) return;
    }

    try {
      final commune = await _obtenirNomCommune(latitude, longitude);
      if (commune == null) return;

      // Annonce uniquement si la commune a changé
      if (commune == _communeActuelle) return;
      _communeActuelle = commune;
      _derniereAnnonce = DateTime.now();

      // Récupérer le polygone via Nominatim
      final polygone = await _obtenirPolygoneCommune(commune);

      if (polygone == null) {
        await _annoncerCommune(commune, null, null);
        return;
      }
      _polygoneActuel = polygone;

      // Compter les POIs dans la commune
      final poisDansCommune = pointsInteret.where((poi) {
        if (poi.status != PoiStatus.validated) return false;
        return _estDansPolygone(poi.position.latitude, poi.position.longitude, polygone);
      }).toList();

      final total = poisDansCommune.length;
      final lus = poisDansCommune.where((p) => poisLusIds.contains(p.id)).length;

      await _annoncerCommune(commune, total, lus);
    } catch (e) {
      print('Erreur CommuneService : $e');
    }
  }

  // -------------------------------------------------------------------------
  // Geocoder — nom de la commune via Nominatim reverse
  // -------------------------------------------------------------------------

  Future<String?> _obtenirNomCommune(double latitude, double longitude) async {
    try {
      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?lat=$latitude&lon=$longitude&format=json&accept-language=fr',
      );
      final response = await http.get(url, headers: {
        'User-Agent': 'FayowApp/1.0',
      }).timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body);
      final address = data['address'] as Map<String, dynamic>?;
      if (address == null) return null;

      // Priorité : city > town > village > municipality
      return address['city'] as String? ??
          address['town'] as String? ??
          address['village'] as String? ??
          address['municipality'] as String?;
    } catch (e) {
      print('Erreur geocoder commune : $e');
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // Nominatim — polygone de la commune
  // -------------------------------------------------------------------------

  Future<List<List<double>>?> _obtenirPolygoneCommune(String commune) async {
    try {
      final nomEncoded = Uri.encodeComponent(commune);
      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?q=$nomEncoded&format=json&polygon_geojson=1&limit=1&countrycodes=fr',
      );
      final response = await http.get(url, headers: {
        'User-Agent': 'FayowApp/1.0',
      }).timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as List;
      if (data.isEmpty) return null;

      final geometry = data[0]['geojson'] as Map<String, dynamic>;
      return _extrairePolygone(geometry);
    } catch (e) {
      print('Erreur polygone commune : $e');
      return null;
    }
  }

  List<List<double>>? _extrairePolygone(Map<String, dynamic> geometry) {
    try {
      final type = geometry['type'] as String;
      final coordinates = geometry['coordinates'] as List;

      final List ring;
      if (type == 'Polygon') {
        ring = coordinates[0] as List;
      } else if (type == 'MultiPolygon') {
        ring = (coordinates[0] as List)[0] as List;
      } else {
        return null;
      }

      return ring.map<List<double>>((point) {
        final p = point as List;
        return [p[1].toDouble(), p[0].toDouble()]; // [lat, lng]
      }).toList();
    } catch (e) {
      print('Erreur extraction polygone : $e');
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // Ray Casting — point dans polygone
  // -------------------------------------------------------------------------

  bool _estDansPolygone(double lat, double lng, List<List<double>> polygone) {
    bool dedans = false;
    int j = polygone.length - 1;
    for (int i = 0; i < polygone.length; i++) {
      final latI = polygone[i][0];
      final lngI = polygone[i][1];
      final latJ = polygone[j][0];
      final lngJ = polygone[j][1];
      if ((lngI > lng) != (lngJ > lng) &&
          lat < (latJ - latI) * (lng - lngI) / (lngJ - lngI) + latI) {
        dedans = !dedans;
      }
      j = i;
    }
    return dedans;
  }

  // -------------------------------------------------------------------------
  // Annonce vocale
  // -------------------------------------------------------------------------

  Future<void> _annoncerCommune(String commune, int? total, int? lus) async {
    if (!_ttsReady) return;

    final String message;
    if (total == null) {
      message = 'Vous êtes à $commune.';
    } else if (total == 0) {
      message = 'Vous êtes à $commune. '
          'Cette commune ne contient pas encore d\'anecdote FaYoW. '
          'N\'hésitez pas à l\'enrichir avec vos propres anecdotes.';
    } else if (lus == null || lus == 0) {
      final s = total > 1 ? 's' : '';
      message = 'Vous êtes à $commune. '
          'Cette commune contient $total anecdote$s FaYoW, '
          'vous n\'en avez encore lu aucune.';
    } else if (lus == total) {
      final s = total > 1 ? 's' : '';
      message = 'Vous êtes à $commune. '
          'Cette commune contient $total anecdote$s FaYoW, '
          'vous les avez toutes lues ! '
          'Mais vous pouvez l\'enrichir avec vos propres anecdotes.';
    } else {
      final s = total > 1 ? 's' : '';
      message = 'Vous êtes à $commune. '
          'Cette commune contient $total anecdote$s FaYoW, '
          'vous en avez lu $lus.';
    }

    print('Annonce commune : $message');
    await _tts.speak(message);
  }
}