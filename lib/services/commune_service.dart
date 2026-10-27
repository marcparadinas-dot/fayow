import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';
import '../models/poi_models.dart';
import 'settings_service.dart';

class CommuneService {
  // -------------------------------------------------------------------------
  // État
  // -------------------------------------------------------------------------

  String? _communeActuelle;
  List<List<double>>? _polygoneActuel;
  DateTime? _derniereAnnonce;

  // Limitation des requêtes réseau (Nominatim)
  DateTime? _derniereVerifReseau;
  List<double>? _dernierePositionVerifiee; // [lat, lng] de la dernière vérification réussie
  static const Duration _intervalleVerifReseau = Duration(seconds: 30);
  static const double _deplacementMinVerifMetres = 100.0;

  // Temporisation : 10 minutes entre deux annonces
  static const Duration _tempoMin = Duration(minutes: 10);

  // TTS dédié aux annonces de commune (voix distincte)
  late FlutterTts _tts;
  bool _ttsReady = false;

  // -------------------------------------------------------------------------
  // Initialisation
  // -------------------------------------------------------------------------

  Future<void> initialiser(FlutterTts ttsInstance) async {
    _tts = ttsInstance; // Utiliser l'instance partagée
    _ttsReady = true;
    // Pas besoin de reconfigurer la langue, déjà fait par TtsService
  }

  void dispose() {
    _tts.stop();
  }

  void reinitialiser() {
    _communeActuelle = null;
    _polygoneActuel = null;
    _derniereAnnonce = null;
    _derniereVerifReseau = null;
    _dernierePositionVerifiee = null;
  }

  // -------------------------------------------------------------------------
  // Point d'entrée principal
  // -------------------------------------------------------------------------

Future<void> verifierCommune({
  required double latitude,
  required double longitude,
  required List<PointInteret> pointsInteret,
  required Set<String> poisLusIds,
  required bool ttsEnCours,
}) async {
  print('=== verifierCommune appelé : ttsEnCours=$ttsEnCours, '
      'pointsInteret=${pointsInteret.length}, '
      'derniereAnnonce=$_derniereAnnonce ===');

  if (ttsEnCours) {
    print('=== Annonce bloquée : TTS en cours ===');
    return;
  }

  if (_derniereAnnonce != null) {
    final elapsed = DateTime.now().difference(_derniereAnnonce!);
    print('=== Temps depuis dernière annonce : ${elapsed.inSeconds}s ===');
    if (elapsed < _tempoMin) {
      print('=== Annonce bloquée : temporisation ===');
      return;
    }
  }
  // --- Économie de réseau et de batterie ---------------------------------
  // 1. Toujours dans la commune déjà identifiée : aucune requête.
  final polygoneConnu = _polygoneActuel;
  if (_communeActuelle != null &&
      polygoneConnu != null &&
      _estDansPolygone(latitude, longitude, polygoneConnu)) {
    return;
  }

  // 2. Sinon, on interroge Nominatim au plus une fois toutes les 30 s et,
  //    si la dernière vérification avait abouti, seulement après 100 m de
  //    déplacement. Avant ce correctif, une requête réseau partait à chaque
  //    mise à jour GPS dès que 10 minutes s'étaient écoulées.
  final maintenant = DateTime.now();
  final derniereVerif = _derniereVerifReseau;
  if (derniereVerif != null &&
      maintenant.difference(derniereVerif) < _intervalleVerifReseau) {
    return;
  }
  final dernierePos = _dernierePositionVerifiee;
  if (dernierePos != null &&
      _distanceMetres(dernierePos, latitude, longitude) <
          _deplacementMinVerifMetres) {
    return;
  }
  _derniereVerifReseau = maintenant;

    try {
      final commune = await _obtenirNomCommune(latitude, longitude);
      if (commune == null) return;
      _dernierePositionVerifiee = [latitude, longitude]; // vérification réussie

      // Annonce uniquement si la commune a changé
      if (commune == _communeActuelle) return;
      _communeActuelle = commune;
      _polygoneActuel = null; // l'ancien polygone n'est plus valable
      _derniereAnnonce = DateTime.now();

      // Récupérer le polygone via Nominatim
      final polygone = await _obtenirPolygoneCommune(commune, latitude, longitude);

      // Toujours mémoriser le polygone (même null) : celui de la commune
      // précédente ne doit pas court-circuiter les vérifications suivantes.
      _polygoneActuel = polygone;

      if (polygone == null) {
        await _annoncerCommune(commune, null, null);
        return;
      }

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

  Future<List<List<double>>?> _obtenirPolygoneCommune(
    String commune,
    double latitude,
    double longitude,
  ) async {
    try {
      final nomEncoded = Uri.encodeComponent(commune);
      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?q=$nomEncoded&format=json&polygon_geojson=1&limit=1'
        '&viewbox=${longitude - 0.5},${latitude + 0.5},${longitude + 0.5},${latitude - 0.5}'
       '&bounded=1',
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

  /// Distance approchée (en mètres) entre un point [lat, lng] et une position.
  /// Suffisante pour un seuil de l'ordre de la centaine de mètres.
  double _distanceMetres(List<double> a, double lat, double lng) {
    const metresParDegre = 111320.0;
    final dLat = (lat - a[0]) * metresParDegre;
    final dLng = (lng - a[1]) * metresParDegre * cos(lat * pi / 180);
    return sqrt(dLat * dLat + dLng * dLng);
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
  // S'assurer que la langue est bien configurée
  await SettingsService.instance.appliquerVoix(_tts);
  await _tts.setSpeechRate(0.5);
  // Petite pause pour s'assurer que le contexte est stable
  await Future.delayed(const Duration(milliseconds: 500));

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
    await _tts.speak(message, focus: true);
  }
}