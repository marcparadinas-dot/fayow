import 'parcourir_screen.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/poi_models.dart';
import '../repository/poi_repository.dart';
import '../services/tts_service.dart';
import '../screens/auth_screen.dart';
import '../services/foreground_service.dart';
import '../services/auth_service.dart';
import '../services/commune_service.dart';
import 'profil_screen.dart';
import '../services/score_service.dart';
import 'classement_screen.dart';
import '../services/mail_service.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  final PoiRepository _poiRepository = PoiRepository();
  final TtsService _ttsService = TtsService();
  final Distance _distance = const Distance();
  final CommuneService _communeService = CommuneService();

  LatLng? _currentPosition;
  bool _locationReady = false;
  bool _modeReaffichage = false;
  bool _poisCharges = false;
  List<PointInteret> _pointsInteret = [];
  Set<String> _poisLusIds = {};
  Set<String> _poisValidesDeclenches = {};  // validated : marqués lus dans Firestore
  Set<String> _poisProposesDeclenches = {}; // proposed : lus localement seulement
  // Ajoutez cette propriété en haut avec les autres
  StreamSubscription<Position>? _locationSubscription;
  late bool _isModerator;
  // Seuil de déclenchement en mètres
  static const double _seuilMetres = 20.0;

@override
void initState() {
  super.initState();
  _ttsService.initialiser();
  _communeService.initialiser(_ttsService.tts); // ← passer l'instance
  _isModerator = AuthService.isModerator;
  _initLocation();
  _chargerPois();
}

@override
void dispose() {
  _locationSubscription?.cancel();
  _ttsService.dispose();
  ForegroundServiceManager.arreter();
  _communeService.dispose();
  super.dispose();
}

Future<void> _chargerPois() async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return;

  final poisValides = await _poiRepository.chargerPoisValides();
  final poisLus = await _poiRepository.chargerPoisLus(uid);
  
  final tousLesPois = [...poisValides];

  if (_isModerator) {
    // Modérateur : charger tous les POIs proposés par tout le monde
    final tousProposed = await _poiRepository.chargerTousPoisProposed();
    for (final poi in tousProposed) {
      if (!tousLesPois.any((p) => p.id == poi.id)) {
        tousLesPois.add(poi);
      }
    }
  }

  // Toujours charger ses propres POIs (initiated)
  final mesPois = await _poiRepository.chargerMesPois(uid);
  for (final poi in mesPois) {
    if (!tousLesPois.any((p) => p.id == poi.id)) {
      tousLesPois.add(poi);
    }
  }

  print('POIs validés : ${poisValides.length}');
  print('Mes POIs : ${mesPois.length}');
  print('POIs lus : ${poisLus.length}');

  setState(() {
    _pointsInteret = tousLesPois;
    _poisLusIds = poisLus;
    _poisCharges = true;
  });
// Initialiser le score si nécessaire (première fois uniquement)
    ScoreService.initialiserScoreSiNecessaire(uid);
  // Déclencher l'annonce commune APRÈS le chargement des POIs
  /*if (_currentPosition != null) {
    _communeService.verifierCommune(
      latitude: _currentPosition!.latitude,
      longitude: _currentPosition!.longitude,
      pointsInteret: _pointsInteret,
      poisLusIds: _poisLusIds,
      ttsEnCours: _ttsService.estEnCoursDeLecture,
    );
  }*/
}

Future<void> _initLocation() async {
  try {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _useFallbackPosition();
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever ||
        permission == LocationPermission.denied) {
      _useFallbackPosition();
      return;
    }

    // Annuler toute subscription précédente
    await _locationSubscription?.cancel();

    _locationSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((position) {
      if (!mounted) return;
      final nouvellePosition = LatLng(position.latitude, position.longitude);

      if (!_locationReady) {
        setState(() {
          _currentPosition = nouvellePosition;
          _locationReady = true;
        });
      } else {
        setState(() {
          _currentPosition = nouvellePosition;
        });
        _mapController.move(nouvellePosition, 16.0);
      }
      _verifierProximite(nouvellePosition);
// Annoncer la commune uniquement après chargement des POIs
if (_poisCharges) {
  _communeService.verifierCommune(
    latitude: position.latitude,
    longitude: position.longitude,
    pointsInteret: _pointsInteret,
    poisLusIds: _poisLusIds,
    ttsEnCours: _ttsService.estEnCoursDeLecture,
  );
}
    }, onError: (e) {
      print('Erreur stream GPS : $e');
      _useFallbackPosition();
    });

  } catch (e) {
    print('Erreur géolocalisation : $e');
    _useFallbackPosition();
  }
}

  void _useFallbackPosition() {
    setState(() {
      _currentPosition = const LatLng(48.8566, 2.3522);
      _locationReady = true;
    });
  }

  /// Vérifie si l'utilisateur est dans le rayon d'un POI VALIDATED non lu
/// Vérifie si l'utilisateur est dans le rayon d'un POI VALIDATED non lu
/// N'est appelée que si le TTS n'est pas en cours de lecture
void _verifierProximite(LatLng position) {
  if (_ttsService.estEnCoursDeLecture) return;

  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return;

  // Chercher d'abord un POI validated non lu
  for (final poi in _pointsInteret) {
    if (poi.status != PoiStatus.validated) continue;
    if (_poisLusIds.contains(poi.id)) continue;
    if (_poisValidesDeclenches.contains(poi.id)) continue;

    final dist = _distance.as(LengthUnit.Meter, position, poi.position);
    if (dist <= _seuilMetres) {
      _declencherPoiValide(poi, uid);
      return;
    }
  }

  // Ensuite chercher un POI proposed non encore déclenché
  for (final poi in _pointsInteret) {
    if (poi.status != PoiStatus.proposed) continue;
    if (_poisProposesDeclenches.contains(poi.id)) continue;

    final dist = _distance.as(LengthUnit.Meter, position, poi.position);
    if (dist <= _seuilMetres) {
      _declencherPoiPropose(poi);
      return;
    }
  }
}

/// POI validated : lu et marqué dans Firestore, cercle retiré
Future<void> _declencherPoiValide(PointInteret poi, String uid) async {
  _poisValidesDeclenches.add(poi.id);

  final lectureCompleter = Completer<void>();
  _afficherDialogPoi(poi.message, lectureTerminee: lectureCompleter.future);
  await _ttsService.lire(poi.message);
  if (!lectureCompleter.isCompleted) lectureCompleter.complete();

  try {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('readPois')
        .doc(poi.id)
        .set({'readAt': FieldValue.serverTimestamp()});
    if (mounted) {
      setState(() { _poisLusIds.add(poi.id); });
// Mettre à jour le score
ScoreService.incrementerPoisLus(uid);

    }
  } catch (e) {
    print('Erreur marquage POI lu : $e');
    _poisValidesDeclenches.remove(poi.id);
  }

  if (_currentPosition != null) {
    _verifierProximite(_currentPosition!);

    // Tenter l'annonce commune après la fin de la lecture
    if (_poisCharges) {
      _communeService.verifierCommune(
        latitude: _currentPosition!.latitude,
        longitude: _currentPosition!.longitude,
        pointsInteret: _pointsInteret,
        poisLusIds: _poisLusIds,
        ttsEnCours: false, // TTS vient de se terminer
      );
    }
  }
}

Future<void> _declencherPoiPropose(PointInteret poi) async {
  _poisProposesDeclenches.add(poi.id);

  final lectureCompleter = Completer<void>();
  _afficherDialogPoi(poi.message, lectureTerminee: lectureCompleter.future);
  await _ttsService.lire(poi.message);
  if (!lectureCompleter.isCompleted) lectureCompleter.complete();

  if (_currentPosition != null) {
    _verifierProximite(_currentPosition!);

    // Tenter l'annonce commune après la fin de la lecture
    if (_poisCharges) {
      _communeService.verifierCommune(
        latitude: _currentPosition!.latitude,
        longitude: _currentPosition!.longitude,
        pointsInteret: _pointsInteret,
        poisLusIds: _poisLusIds,
        ttsEnCours: false,
      );
    }
  }
}

/// Affiche un dialog avec le texte du POI pendant la lecture TTS
// Clé globale pour référencer le dialog POI

void _afficherDialogPoi(String message, {required Future<void> lectureTerminee}) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      lectureTerminee.then((_) {
        // Utiliser dialogContext pour fermer ce dialog précisément
        if (dialogContext.mounted) {
          Navigator.of(dialogContext).pop();
        }
      });
      return AlertDialog(
        content: Text(message),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Fermer'),
          ),
        ],
      );
    },
  );
}
/// Ferme le dialog du POI
void _fermerDialogPoi() {
  if (mounted && Navigator.canPop(context)) {
    Navigator.pop(context);
  }
}

void _onAjouterPoiClicked() {
  final position = _currentPosition;
  if (position == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Localisation indisponible')),
    );
    return;
  }

  final textController = TextEditingController();

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Nouvelle anecdote'),
      content: TextField(
        controller: textController,
        decoration: const InputDecoration(
          hintText: 'Message de l\'anecdote',
        ),
        maxLines: 4,
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        ElevatedButton(
          onPressed: () async {
            final message = textController.text.trim();
            if (message.isEmpty) return;
            Navigator.pop(context);

            final uid = FirebaseAuth.instance.currentUser?.uid;
            if (uid == null) return;

            try {
              await _poiRepository.ajouterPoi(
                latitude: position.latitude,
                longitude: position.longitude,
                message: message,
                creatorUid: uid,
              );
              await _chargerPois();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Brouillon enregistré')),
                );
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Erreur : $e')),
                );
              }
            }
          },
          child: const Text('Enregistrer'),
        ),
      ],
    ),
  );
}

/*
  Future<void> _signOut() async {
    _ttsService.arreter();
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => AuthScreen()),
      );
    }
  }
*/
  Color _getCercleColor(PointInteret poi) {
    switch (poi.status) {
      case PoiStatus.validated:
        return Colors.purple.withOpacity(0.4);
      case PoiStatus.initiated:
        return Colors.orange.withOpacity(0.5);
      case PoiStatus.proposed:
        return Colors.grey.withOpacity(0.5);
    }
  }

  Color _getCercleBorderColor(PointInteret poi) {
    switch (poi.status) {
      case PoiStatus.validated:
        return Colors.purple;
      case PoiStatus.initiated:
        return Colors.orange;
      case PoiStatus.proposed:
        return Colors.grey;
    }
  }

List<CircleMarker> _buildCercles() {
  return _pointsInteret
      .where((poi) => !_poisLusIds.contains(poi.id))
      .map((poi) => CircleMarker(
            point: poi.position,
            radius: 20,
            useRadiusInMeter: true,
            color: _getCercleColor(poi),
            borderColor: _getCercleBorderColor(poi),
            borderStrokeWidth: 3,
          ))
      .toList();
}

void _onCarteTappee(LatLng tapLatLng) {
  const double seuilMetres = 30.0;

  PointInteret? poiTouche;
  double distanceMin = double.infinity;

  for (final poi in _pointsInteret) {
    // Utilisateur normal : seulement INITIATED
    // Modérateur : INITIATED + PROPOSED
    if (poi.status == PoiStatus.validated) continue;
    if (!_isModerator && poi.status == PoiStatus.proposed) continue;

    final dist = _distance.as(LengthUnit.Meter, tapLatLng, poi.position);
    if (dist < seuilMetres && dist < distanceMin) {
      distanceMin = dist;
      poiTouche = poi;
    }
  }

  if (poiTouche != null) {
    if (poiTouche.status == PoiStatus.proposed && _isModerator) {
      _afficherDialogModerationPoi(poiTouche);
    } else {
      _afficherDialogEditionPoi(poiTouche);
    }
  }
}

void _afficherDialogEditionPoi(PointInteret poi) {
  final textController = TextEditingController(text: poi.message);

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Modifier votre brouillon'),
      content: TextField(
        controller: textController,
        decoration: const InputDecoration(
          hintText: 'Message de l\'anecdote',
        ),
        maxLines: 4,
      ),
      actions: [
        // Annuler
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        // Proposer à la modération
        TextButton(
          onPressed: () async {
            final message = textController.text.trim();
            if (message.isEmpty) return;
            Navigator.pop(context);

            try {
              await _poiRepository.mettreAJourPoi(
                poi.id,
                {
                  'message': message,
                  'status': 'proposed',
                },
              );
              await _chargerPois();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('POI proposé à la modération !')),
                );
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Erreur : $e')),
                );
              }
            }
          },
          child: const Text('Proposer à la modération',
              style: TextStyle(color: Colors.orange)),
        ),
        // Enregistrer
        ElevatedButton(
          onPressed: () async {
            final message = textController.text.trim();
            if (message.isEmpty) return;
            Navigator.pop(context);

            try {
              await _poiRepository.mettreAJourPoi(
                poi.id,
                {'message': message},
              );
              await _chargerPois();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Brouillon mis à jour')),
                );
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Erreur : $e')),
                );
              }
            }
          },
          child: const Text('Enregistrer'),
        ),
      ],
    ),
  );
}

/// Affiche la liste des POIs proposés à modérer
Future<void> _afficherModerationDialog() async {
  final poisProposed = _pointsInteret
      .where((p) => p.status == PoiStatus.proposed)
      .toList();

  if (poisProposed.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Aucune anecdote en attente')),
    );
    return;
  }

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${poisProposed.length} anecdote(s) en attente'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: poisProposed.length,
          itemBuilder: (context, index) {
            final poi = poisProposed[index];
            return ListTile(
              title: Text(
                poi.message.length > 50
                    ? '${poi.message.substring(0, 50)}...'
                    : poi.message,
                style: const TextStyle(fontSize: 14),
              ),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () {
                Navigator.pop(context);
                _afficherDialogModerationPoi(poi);
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fermer'),
        ),
      ],
    ),
  );
}

/// Dialog d'édition/validation d'un POI proposé
void _afficherDialogModerationPoi(PointInteret poi) {
  final textController = TextEditingController(text: poi.message);

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Modérer une anecdote'),
      content: TextField(
        controller: textController,
        decoration: const InputDecoration(
          hintText: 'Message de l\'anecdote',
        ),
        maxLines: 4,
      ),
      actions: [
        // Annuler
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        // Rejeter → repasser en initiated
        TextButton(
          onPressed: () async {
            Navigator.pop(context);
            await _afficherDialogRejetAvecMotif(poi);
          },
          child: const Text('Rejeter', style: TextStyle(color: Colors.red)),
        ),

        // Valider
        ElevatedButton(
          onPressed: () async {
            final message = textController.text.trim();
            if (message.isEmpty) return;
            Navigator.pop(context);
            try {
              await _poiRepository.mettreAJourPoi(
                poi.id,
                {
                  'message': message,
                  'status': 'validated',
                  'approved': true,
                },
              );
              await _chargerPois();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Anecdote validée !')),
                );
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Erreur : $e')),
                );
              }
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
          ),
          child: const Text('Valider'),
        ),
      ],
    ),
  );
}

void _onReafficherClicked() {
  if (_modeReaffichage) {
    // Réinitialiser → recharger depuis Firestore
    setState(() => _modeReaffichage = false);
    _chargerPois();
    return;
  }

  // Afficher les options
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Réafficher des anecdotes'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
      ],
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: const Text('Par secteur'),
            leading: const Icon(Icons.location_on),
            onTap: () {
              Navigator.pop(context);
              _reafficherParSecteur();
            },
          ),
          ListTile(
            title: const Text('Par date'),
            leading: const Icon(Icons.calendar_today),
            onTap: () {
              Navigator.pop(context);
              _reafficherParDate();
            },
          ),
        ],
      ),
    ),
  );
}

void _reafficherParSecteur() {
  final position = _currentPosition;
  if (position == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Localisation indisponible')),
    );
    return;
  }

  final rayons = ['100 mètres', '500 mètres', '1 kilomètre', '5 kilomètres'];
  final rayonsMetres = [100.0, 500.0, 1000.0, 5000.0];

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Choisissez un rayon'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(rayons.length, (i) => ListTile(
          title: Text(rayons[i]),
          onTap: () {
            Navigator.pop(context);
            _appliquerReaffichageParSecteur(position, rayonsMetres[i]);
          },
        )),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
      ],
    ),
  );
}

void _appliquerReaffichageParSecteur(LatLng centre, double rayonMetres) {
  final poisDansLeRayon = _pointsInteret
      .where((poi) => poi.status == PoiStatus.validated)
      .where((poi) => _poisLusIds.contains(poi.id))
      .where((poi) {
        final dist = _distance.as(LengthUnit.Meter, centre, poi.position);
        return dist <= rayonMetres;
      })
      .map((poi) => poi.id)
      .toSet();

  if (poisDansLeRayon.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Aucune anecdote lue dans ce secteur')),
    );
    return;
  }

  setState(() {
    _poisLusIds.removeAll(poisDansLeRayon);
    _poisValidesDeclenches.removeAll(poisDansLeRayon);
    _modeReaffichage = true;
  });

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('${poisDansLeRayon.length} anecdote(s) réaffichée(s)')),
  );
  if (_currentPosition != null) {
  _verifierProximite(_currentPosition!);
}
}

void _reafficherParDate() {
  final periodes = ['Aujourd\'hui', 'Cette semaine', 'Ce mois-ci', 'Cette année'];

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Réafficher depuis...'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(periodes.length, (i) => ListTile(
          title: Text(periodes[i]),
          onTap: () {
            Navigator.pop(context);
            _appliquerReaffichageParDate(i);
          },
        )),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
      ],
    ),
  );
}

Future<void> _appliquerReaffichageParDate(int periodeIndex) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return;

  final now = DateTime.now();
  final DateTime depuis = switch (periodeIndex) {
    0 => DateTime(now.year, now.month, now.day),        // Aujourd'hui
    1 => now.subtract(const Duration(days: 7)),          // Cette semaine
    2 => DateTime(now.year, now.month, 1),               // Ce mois-ci
    3 => DateTime(now.year, 1, 1),                       // Cette année
    _ => now.subtract(const Duration(days: 7)),
  };

  try {
    // Charger les POIs lus depuis cette date depuis Firestore
    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('readPois')
        .where('readAt', isGreaterThanOrEqualTo: Timestamp.fromDate(depuis))
        .get();

    final ids = snapshot.docs.map((doc) => doc.id).toSet();

    if (ids.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Aucune anecdote lue sur cette période')),
        );
      }
      return;
    }

    setState(() {
      _poisLusIds.removeAll(ids);
      _poisValidesDeclenches.removeAll(ids);
      _modeReaffichage = true;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${ids.length} anecdote(s) réaffichée(s)')),
      );
    }
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur : $e')),
      );
    }
  }
  if (_currentPosition != null) {
  _verifierProximite(_currentPosition!);
}
}

Future<void> _afficherDialogRejetAvecMotif(PointInteret poi) async {
  // 1. Charger les motifs depuis Firestore
  final motifs = await MailService.chargerMotifsRejet();
 
  if (motifs.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Impossible de charger les motifs')),
    );
    return;
  }
 
  // 2. État local du dialog
  final motifsSelectionnes = <String>{};
  final commentaireController = TextEditingController();
 
  // 3. Afficher le dialog de sélection
  final confirme = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setStateDialog) => AlertDialog(
        title: const Text('Motif du rejet'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Aperçu du POI
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.grey[300]!),
                ),
                child: Text(
                  poi.message.length > 80
                      ? '${poi.message.substring(0, 80)}...'
                      : poi.message,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[700],
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
              const SizedBox(height: 16),
 
              // Titre motifs
              const Text(
                'Sélectionnez les motifs (plusieurs possibles) :',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
 
              // Liste des motifs avec cases à cocher
              ...motifs.map((motif) => CheckboxListTile(
                    value: motifsSelectionnes.contains(motif),
                    onChanged: (checked) {
                      setStateDialog(() {
                        if (checked == true) {
                          motifsSelectionnes.add(motif);
                        } else {
                          motifsSelectionnes.remove(motif);
                        }
                      });
                    },
                    title: Text(
                      motif,
                      style: const TextStyle(fontSize: 13),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  )),
 
              const SizedBox(height: 16),
 
              // Commentaire facultatif
              const Text(
                'Commentaire (facultatif) :',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: commentaireController,
                decoration: InputDecoration(
                  hintText: 'Précisions supplémentaires...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                  contentPadding: const EdgeInsets.all(10),
                ),
                maxLines: 3,
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            onPressed: motifsSelectionnes.isEmpty
                ? null // Désactivé si aucun motif sélectionné
                : () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              disabledBackgroundColor: Colors.grey[300],
            ),
            child: const Text('Rejeter et notifier'),
          ),
        ],
      ),
    ),
  );
 
  if (confirme != true) return;
 
  try {
    // 4. Repasser le POI en initiated
    await _poiRepository.mettreAJourPoi(poi.id, {'status': 'initiated'});
 
    // 5. Récupérer email et pseudo de l'auteur
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(poi.creatorUid)
        .get();
    final email  = userDoc.data()?['email']  as String?;
    final pseudo = userDoc.data()?['pseudo'] as String? ?? 'Utilisateur';
 
    // 6. Envoyer l'email si disponible
    if (email != null && email.isNotEmpty) {
      await MailService.envoyerEmailRejet(
        emailDestinataire:    email,
        pseudoDestinataire:   pseudo,
        messagePoiApercu:     poi.message,
        motifsSelectionnes:   motifsSelectionnes.toList(),
        commentaire:          commentaireController.text.trim(),
      );
    }
 
    // 7. Recharger les POIs
    final index = _pointsInteret.indexWhere((p) => p.id == poi.id);
    if (index != -1) {
      setState(() {
        _pointsInteret[index] = PointInteret(
          id: poi.id,
          position: poi.position,
          message: poi.message,
          status: PoiStatus.initiated,
          creatorUid: poi.creatorUid,
        );
      });
    }
    await _chargerPois();
    //setState(() {}); // Forcer le rafraîchissement visuel
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            email != null && email.isNotEmpty
                ? 'Anecdote rejetée · $pseudo notifié par email ✓'
                : 'Anecdote rejetée (email non disponible)',
          ),
        ),
      );
    }
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur : $e')),
      );
    }
  }
}


  @override
@override
Widget build(BuildContext context) {
  return Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          // Bandeau haut avec image
          SizedBox(
            width: double.infinity,
            height: 110,
            child: Image.asset(
              'assets/images/fayow_bandeau_haut.png',
              fit: BoxFit.cover,
            ),
          ),

          // Carte
          Expanded(
            child: _locationReady
                ? FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: _currentPosition!,
                      initialZoom: 16.0,
                      onTap: (tapPosition, latLng) =>
                          _onCarteTappee(latLng),
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
                        subdomains: const ['a', 'b', 'c', 'd'],
                        userAgentPackageName: 'com.example.fayow',
                      ),
                      CircleLayer(circles: _buildCercles()),
                      MarkerLayer(
                        markers: [
                          if (_currentPosition != null)
                            Marker(
                              point: _currentPosition!,
                              width: 40,
                              height: 40,
                              child: const Icon(
                                Icons.navigation,
                                color: Colors.blue,
                                size: 40,
                              ),
                            ),
                        ],
                      ),
                    ],
                  )
                : const Center(child: CircularProgressIndicator()),
          ),

          // Boutons Modération + Ajouter (au-dessus de la barre du bas)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Row(
              children: [
                if (_isModerator)
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _afficherModerationDialog,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.indigo,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Modération',
                          style: TextStyle(fontSize: 12)),
                    ),
                  ),
                if (_isModerator) const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _onAjouterPoiClicked,
                    icon: const Icon(Icons.add_location_alt, size: 16),
                    label: const Text('Ajouter Anecdote',
                        style: TextStyle(fontSize: 12)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepPurple,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),

                    // Bandeau bas : image en fond, boutons par-dessus
          Container(
            width: double.infinity,
            height: 110,
            decoration: const BoxDecoration(
              image: DecorationImage(
                image: AssetImage('assets/images/fayow_bandeau_bas.png'),
                fit: BoxFit.cover,
              ),
            ),
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: 
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                  onPressed: _onReafficherClicked,
                  style: (_modeReaffichage
                    ? ElevatedButton.styleFrom(backgroundColor: Colors.orange)
                    : ElevatedButton.styleFrom(
                  backgroundColor: const Color.fromRGBO(230, 157, 217, 1).withOpacity(0.85),
                  foregroundColor: Colors.white,
                ))
                .copyWith(
                  textStyle: WidgetStateProperty.all(
                  const TextStyle(fontSize: 11),
                  ),
                ),
                  child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(_modeReaffichage ? 'Retour' : 'Réafficher\nanecdotes'),
                  ),
              ),
        ),
        const SizedBox(width: 4),
          Expanded(
            child: ElevatedButton(
              onPressed: () async {
              if (_currentPosition == null) return;
                await Navigator.push(
                  context,
                   MaterialPageRoute(
                     builder: (_) => ParcourirScreen(
                     positionInitiale: _currentPosition!,
                     pointsInteret: _pointsInteret,
                     poisLusIds: _poisLusIds,
                     ),
                   ),
               );
                   // Recharger les POIs au retour de ParcourirScreen
              await _chargerPois();
              },
              style: ElevatedButton.styleFrom(
              backgroundColor: const Color.fromRGBO(18, 119, 63, 1).withOpacity(0.85),
              foregroundColor: Colors.white,
              ).copyWith(
                textStyle: WidgetStateProperty.all(
                  const TextStyle(fontSize: 11),
                ),
              ),
              child: const FittedBox(
              fit: BoxFit.scaleDown,
              child: Text('Voir mes\nanecdotes'),
              ),
            ),
          ),
        /*
        const SizedBox(width: 4),
          Expanded(
            child: ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ClassementScreen()),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color.fromRGBO(230, 131, 18, 1).withOpacity(0.85),
                foregroundColor: Colors.white,
              ),
              child: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('Classement'),
              ),
            ),
          ),
          */
        const SizedBox(width: 4),
          Expanded(
            child: ElevatedButton(
            onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProfilScreen()),
              );
            },
            style: ElevatedButton.styleFrom(
            backgroundColor: Colors.deepPurple.withOpacity(0.85),
            foregroundColor: Colors.white,
            ),
            child: const FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('Profil'),
            ),
            ),
          ),
    ],
            ),
          ),
        ],
      ),
    ),
  );
}
}