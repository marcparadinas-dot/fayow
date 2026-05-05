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

  LatLng? _currentPosition;
  bool _locationReady = false;
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
  _isModerator = AuthService.isModerator;
  _ttsService.initialiser();
  _initLocation();
  _chargerPois();
  ForegroundServiceManager.demarrer();
}

@override
void dispose() {
  _locationSubscription?.cancel();
  _ttsService.dispose();
  ForegroundServiceManager.arreter();
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
  });
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

  // Afficher le dialog avant la lecture
  _afficherDialogPoi(poi.message);

  await _ttsService.lire(poi.message);

  // Fermer le dialog après la lecture
  _fermerDialogPoi();

  try {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('readPois')
        .doc(poi.id)
        .set({'readAt': FieldValue.serverTimestamp()});

    if (mounted) {
      setState(() {
        _poisLusIds.add(poi.id);
      });
    }
    print('POI validé ${poi.id} marqué comme lu');
  } catch (e) {
    print('Erreur marquage POI lu : $e');
    _poisValidesDeclenches.remove(poi.id);
  }

  if (_currentPosition != null) {
    _verifierProximite(_currentPosition!);
  }
}

Future<void> _declencherPoiPropose(PointInteret poi) async {
  _poisProposesDeclenches.add(poi.id);

  // Afficher le dialog avant la lecture
  _afficherDialogPoi(poi.message);

  await _ttsService.lire(poi.message);

  // Fermer le dialog après la lecture
  _fermerDialogPoi();

  print('POI proposé ${poi.id} lu localement');

  if (_currentPosition != null) {
    _verifierProximite(_currentPosition!);
  }
}

/// Affiche un dialog avec le texte du POI pendant la lecture TTS
void _afficherDialogPoi(String message) {
  showDialog(
    context: context,
    barrierDismissible: false, // Ne se ferme pas en tapant à côté
    builder: (context) => AlertDialog(
      content: Text(message),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
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
            try {
              await _poiRepository.mettreAJourPoi(
                poi.id,
                {'status': 'initiated'},
              );
              await _chargerPois();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Anecdote rejetée')),
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
          child: const Text('Rejeter',
              style: TextStyle(color: Colors.red)),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _locationReady
                  ? FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: _currentPosition!,
                        initialZoom: 16.0,
                        onTap: (tapPosition, latLng) => _onCarteTappee(latLng),
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
            
            // Barre du bas
Container(
  color: Colors.white,
  padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
  child: Column(
    mainAxisSize: MainAxisSize.min,
    children: [
Row(
  children: [
    Expanded(
      child: ElevatedButton(
        onPressed: _chargerPois,
        child: const Text('Réafficher',
            style: TextStyle(fontSize: 12)),
      ),
    ),
    const SizedBox(width: 4),
    Expanded(
      child: ElevatedButton(
        onPressed: () {
        if (_currentPosition == null) return;
          Navigator.push(
            context,
          MaterialPageRoute(
            builder: (_) => ParcourirScreen(
              positionInitiale: _currentPosition!,
              pointsInteret: _pointsInteret,
              poisLusIds: _poisLusIds,
            ),
          ),
        );
        },
        child: const Text('Parcourir',
            style: TextStyle(fontSize: 12)),
      ),
    ),
    // Bouton Modération visible uniquement pour le modérateur
    if (_isModerator) ...[
      const SizedBox(width: 4),
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
    ],
    const SizedBox(width: 4),
    Expanded(
      child: ElevatedButton(
        onPressed: _signOut,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.red,
          foregroundColor: Colors.white,
        ),
        child: const Text('Déconnexion',
            style: TextStyle(fontSize: 12)),
      ),
    ),
  ],
),
      const SizedBox(height: 4),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: _onAjouterPoiClicked,
          icon: const Icon(Icons.add_location_alt),
          label: const Text('Ajouter Anecdote'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.deepPurple,
            foregroundColor: Colors.white,
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