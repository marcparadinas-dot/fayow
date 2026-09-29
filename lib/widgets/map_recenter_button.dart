import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Bouton de recentrage à superposer à une [FlutterMap].
///
/// N'apparaît que lorsque le centre de la carte s'écarte de plus de
/// [seuilMetres] de la position de l'utilisateur. Au tap, appelle
/// [onRecenter] (c'est l'écran parent qui déplace la carte).
class MapRecenterButton extends StatefulWidget {
  final MapController mapController;
  final LatLng userPosition;
  final VoidCallback onRecenter;
  final double seuilMetres;
  final EdgeInsetsGeometry margin;

  const MapRecenterButton({
    super.key,
    required this.mapController,
    required this.userPosition,
    required this.onRecenter,
    this.seuilMetres = 25.0,
    this.margin = const EdgeInsets.only(bottom: 24, right: 12),
  });

  @override
  State<MapRecenterButton> createState() => _MapRecenterButtonState();
}

class _MapRecenterButtonState extends State<MapRecenterButton> {
  static const Distance _distance = Distance();
  StreamSubscription<MapEvent>? _mapEventSub;

  @override
  void initState() {
    super.initState();
    // Reconstruit le bouton à chaque mouvement de la carte
    _mapEventSub = widget.mapController.mapEventStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _mapEventSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final centre = widget.mapController.camera.center;
    final ecart =
        _distance.as(LengthUnit.Meter, centre, widget.userPosition);
    final estCentree = ecart <= widget.seuilMetres;

    return Positioned(
      bottom: 0,
      right: 0,
      child: Padding(
        padding: widget.margin,
        child: AnimatedOpacity(
          opacity: estCentree ? 0.0 : 1.0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: estCentree,
            child: Material(
              color: Colors.white,
              shape: const CircleBorder(),
              elevation: 3,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: widget.onRecenter,
                child: const Padding(
                  padding: EdgeInsets.all(10.0),
                  child: Icon(
                    Icons.my_location,
                    color: Colors.blue,
                    size: 26,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}