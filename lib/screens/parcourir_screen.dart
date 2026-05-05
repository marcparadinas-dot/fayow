import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/poi_models.dart';
import '../repository/poi_repository.dart';
import '../services/auth_service.dart';


class ParcourirScreen extends StatefulWidget {
  final LatLng positionInitiale;
  final List<PointInteret> pointsInteret;
  final Set<String> poisLusIds;

  const ParcourirScreen({
    super.key,
    required this.positionInitiale,
    required this.pointsInteret,
    required this.poisLusIds,
  });

  @override
  State<ParcourirScreen> createState() => _ParcourirScreenState();
}

class _ParcourirScreenState extends State<ParcourirScreen> {
  final MapController _mapController = MapController();
  final PoiRepository _poiRepository = PoiRepository();
  final Distance _distance = const Distance();

  late List<PointInteret> _pointsInteret;
  late Set<String> _poisLusIds;
  late bool _isModerator;

  // Drag & drop
  PointInteret? _poiEnDeplacement;
  LatLng? _positionDrag;

  @override
  void initState() {
    super.initState();
    _pointsInteret = List.from(widget.pointsInteret);
    _poisLusIds = Set.from(widget.poisLusIds);
    _isModerator = AuthService.isModerator;
  }

  // -------------------------------------------------------------------------
  // Couleurs des cercles
  // -------------------------------------------------------------------------

  Color _getCercleColor(PointInteret poi) {
    if (poi.status == PoiStatus.validated && _poisLusIds.contains(poi.id)) {
      return Colors.green.withOpacity(0.4); // Vert : lu
    }
    if (poi.status == PoiStatus.validated && _isModerator) {
      return Colors.purple.withOpacity(0.3); // Violet : modérateur
    }
    switch (poi.status) {
      case PoiStatus.initiated:
        return Colors.orange.withOpacity(0.5);
      case PoiStatus.proposed:
        return Colors.grey.withOpacity(0.5);
      case PoiStatus.validated:
        return Colors.transparent;
    }
  }

  Color _getCercleBorderColor(PointInteret poi) {
    if (poi.status == PoiStatus.validated && _poisLusIds.contains(poi.id)) {
      return Colors.green;
    }
    if (poi.status == PoiStatus.validated && _isModerator) {
      return Colors.purple;
    }
    switch (poi.status) {
      case PoiStatus.initiated:
        return Colors.orange;
      case PoiStatus.proposed:
        return Colors.grey;
      case PoiStatus.validated:
        return Colors.transparent;
    }
  }

  // -------------------------------------------------------------------------
  // Construction des cercles
  // -------------------------------------------------------------------------

  List<CircleMarker> _buildCercles() {
    final cercles = <CircleMarker>[];

    for (final poi in _pointsInteret) {
      final estLu = _poisLusIds.contains(poi.id);

      // Cercle fantôme pendant le drag
      if (_poiEnDeplacement?.id == poi.id && _positionDrag != null) {
        cercles.add(CircleMarker(
          point: _positionDrag!,
          radius: 20,
          useRadiusInMeter: true,
          color: Colors.orange.withOpacity(0.3),
          borderColor: Colors.orange,
          borderStrokeWidth: 3,
        ));
        continue;
      }

      final afficher = switch (poi.status) {
        PoiStatus.validated => estLu || _isModerator,
        PoiStatus.initiated => true,
        PoiStatus.proposed => true,
      };

      if (!afficher) continue;

      cercles.add(CircleMarker(
        point: poi.position,
        radius: 20,
        useRadiusInMeter: true,
        color: _getCercleColor(poi),
        borderColor: _getCercleBorderColor(poi),
        borderStrokeWidth: 3,
      ));
    }

    return cercles;
  }

  // -------------------------------------------------------------------------
  // Tap sur la carte
  // -------------------------------------------------------------------------

  void _onCarteTappee(LatLng tapLatLng) {
    if (_poiEnDeplacement != null) return;

    const double seuilMetres = 30.0;
    PointInteret? poiTouche;
    double distanceMin = double.infinity;

    for (final poi in _pointsInteret) {
      final estLu = _poisLusIds.contains(poi.id);

      final cliquable = switch (poi.status) {
        PoiStatus.validated => estLu || _isModerator,
        PoiStatus.initiated => true,
        PoiStatus.proposed => true,
      };

      if (!cliquable) continue;

      final dist = _distance.as(LengthUnit.Meter, tapLatLng, poi.position);
      if (dist < seuilMetres && dist < distanceMin) {
        distanceMin = dist;
        poiTouche = poi;
      }
    }

    if (poiTouche == null) return;

    final estLu = _poisLusIds.contains(poiTouche.id);

    switch (poiTouche.status) {
      case PoiStatus.validated:
        // Vert ou violet → afficher le texte
        _afficherDialogTexte(poiTouche.message);
      case PoiStatus.initiated:
        // Orange → édition
        _afficherDialogEdition(poiTouche);
      case PoiStatus.proposed:
        if (_isModerator) {
          // Gris modérateur → modération
          _afficherDialogModeration(poiTouche);
        } else {
          // Gris utilisateur → texte
          _afficherDialogTexte(poiTouche.message);
        }
    }
  }

  // -------------------------------------------------------------------------
  // Long press → drag & drop
  // -------------------------------------------------------------------------

  void _onCarteLongPress(LatLng tapLatLng) {
    const double seuilMetres = 30.0;
    final uid = FirebaseAuth.instance.currentUser?.uid;

    PointInteret? poiCible;
    double distanceMin = double.infinity;

    for (final poi in _pointsInteret) {
      final deplacable = switch (poi.status) {
        PoiStatus.initiated => poi.creatorUid == uid,
        PoiStatus.validated => _isModerator,
        PoiStatus.proposed => _isModerator,
      };

      if (!deplacable) continue;

      final dist = _distance.as(LengthUnit.Meter, tapLatLng, poi.position);
      if (dist < seuilMetres && dist < distanceMin) {
        distanceMin = dist;
        poiCible = poi;
      }
    }

    if (poiCible == null) return;

    setState(() {
      _poiEnDeplacement = poiCible;
      _positionDrag = poiCible!.position;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Faites glisser pour repositionner'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _onCarteDrag(LatLng position) {
    if (_poiEnDeplacement == null) return;
    setState(() => _positionDrag = position);
  }

  void _onCarteRelache(LatLng position) {
    if (_poiEnDeplacement == null) return;
    final poi = _poiEnDeplacement!;
    final nouvellePosition = position;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Confirmer le déplacement ?'),
        content: Text(
          'Lat : ${nouvellePosition.latitude.toStringAsFixed(6)}\n'
          'Lng : ${nouvellePosition.longitude.toStringAsFixed(6)}',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _poiEnDeplacement = null;
                _positionDrag = null;
              });
            },
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await _poiRepository.mettreAJourPoi(poi.id, {
                  'lat': nouvellePosition.latitude,
                  'lng': nouvellePosition.longitude,
                });
                final index = _pointsInteret.indexOfFirst(
                    (p) => p.id == poi.id);
                if (index != -1) {
                  setState(() {
                    _pointsInteret[index] =
                        _pointsInteret[index].copyWith(
                            position: nouvellePosition);
                    _poiEnDeplacement = null;
                    _positionDrag = null;
                  });
                }
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Position mise à jour ✓')),
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
            child: const Text('Valider'),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Dialogs
  // -------------------------------------------------------------------------

  void _afficherDialogTexte(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Anecdote'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
  }

  void _afficherDialogEdition(PointInteret poi) {
    final textController = TextEditingController(text: poi.message);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Modifier votre brouillon'),
        content: TextField(
          controller: textController,
          maxLines: 4,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () async {
              final message = textController.text.trim();
              if (message.isEmpty) return;
              Navigator.pop(context);
              await _poiRepository.mettreAJourPoi(
                  poi.id, {'message': message, 'status': 'proposed'});
              _recharger();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('POI proposé à la modération !')),
                );
              }
            },
            child: const Text('Proposer',
                style: TextStyle(color: Colors.orange)),
          ),
          ElevatedButton(
            onPressed: () async {
              final message = textController.text.trim();
              if (message.isEmpty) return;
              Navigator.pop(context);
              await _poiRepository.mettreAJourPoi(
                  poi.id, {'message': message});
              _recharger();
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }

  void _afficherDialogModeration(PointInteret poi) {
    final textController = TextEditingController(text: poi.message);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Modérer une anecdote'),
        content: TextField(
          controller: textController,
          maxLines: 4,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _poiRepository.mettreAJourPoi(
                  poi.id, {'status': 'initiated'});
              _recharger();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Anecdote rejetée')),
                );
              }
            },
            child: const Text('Rejeter',
                style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            onPressed: () async {
              final message = textController.text.trim();
              if (message.isEmpty) return;
              Navigator.pop(context);
              await _poiRepository.mettreAJourPoi(poi.id, {
                'message': message,
                'status': 'validated',
                'approved': true,
              });
              _recharger();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Anecdote validée !')),
                );
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

  Future<void> _recharger() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final poisValides = await _poiRepository.chargerPoisValides();
    final mesPois = await _poiRepository.chargerMesPois(uid);
    final poisLus = await _poiRepository.chargerPoisLus(uid);
    final tousLesPois = [...poisValides];
    for (final poi in mesPois) {
      if (!tousLesPois.any((p) => p.id == poi.id)) {
        tousLesPois.add(poi);
      }
    }
    if (_isModerator) {
      final proposed = await _poiRepository.chargerTousPoisProposed();
      for (final poi in proposed) {
        if (!tousLesPois.any((p) => p.id == poi.id)) {
          tousLesPois.add(poi);
        }
      }
    }
    if (mounted) {
      setState(() {
        _pointsInteret = tousLesPois;
        _poisLusIds = poisLus;
      });
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Parcourir mes anecdotes'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      body: GestureDetector(
        onLongPressStart: (details) {
          final latLng = _mapController.camera.pointToLatLng(
            math.Point(
              details.localPosition.dx,
              details.localPosition.dy,
            ),
          );
          _onCarteLongPress(latLng);
        },
        onLongPressMoveUpdate: (details) {
          if (_poiEnDeplacement == null) return;
          final latLng = _mapController.camera.pointToLatLng(
            math.Point(
              details.localPosition.dx,
              details.localPosition.dy,
            ),
          );
          _onCarteDrag(latLng);
        },
        onLongPressEnd: (details) {
          if (_poiEnDeplacement == null) return;
          final latLng = _mapController.camera.pointToLatLng(
            math.Point(
              details.localPosition.dx,
              details.localPosition.dy,
            ),
          );
          _onCarteRelache(latLng);
        },
        child: FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: widget.positionInitiale,
            initialZoom: 16.0,
            // Pas de recentrage automatique
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
          ],
        ),
      ),
    );
  }
}

// Extension utilitaire
extension ListExtension<T> on List<T> {
  int indexOfFirst(bool Function(T) test) {
    for (var i = 0; i < length; i++) {
      if (test(this[i])) return i;
    }
    return -1;
  }
}