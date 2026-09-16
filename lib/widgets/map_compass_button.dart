import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

/// Bouton boussole à superposer à une [FlutterMap].
///
/// - N'apparaît que lorsque la carte est tournée (rotation != 0), avec un
///   fondu d'apparition/disparition.
/// - L'icône pivote pour toujours pointer vers le vrai nord, comme sur
///   Google Maps / Plans.
/// - Au tap, remet la carte face au nord (rotation = 0) avec une animation
///   fluide, en choisissant le sens de rotation le plus court.
class MapCompassButton extends StatefulWidget {
  final MapController mapController;
  final EdgeInsetsGeometry margin;

  const MapCompassButton({
    super.key,
    required this.mapController,
    this.margin = const EdgeInsets.only(top: 12, right: 12),
  });

  @override
  State<MapCompassButton> createState() => _MapCompassButtonState();
}

class _MapCompassButtonState extends State<MapCompassButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  StreamSubscription<MapEvent>? _mapEventSub;
  double _rotationDeg = 0.0;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _rotationDeg = widget.mapController.camera.rotation;
    _mapEventSub = widget.mapController.mapEventStream.listen((event) {
      final nouvelleRotation = widget.mapController.camera.rotation;
      if (nouvelleRotation != _rotationDeg && mounted) {
        setState(() => _rotationDeg = nouvelleRotation);
      }
    });
  }

  @override
  void dispose() {
    _mapEventSub?.cancel();
    _animController.dispose();
    super.dispose();
  }

  void _recentrerVersLeNord() {
    final depart = widget.mapController.camera.rotation;

    // Chemin le plus court vers 0° (évite un tour complet inutile)
    double delta = (0.0 - depart) % 360;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    final arrivee = depart + delta;

    final animation = Tween<double>(begin: depart, end: arrivee).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );

    void listener() => widget.mapController.rotate(animation.value);

    animation.addListener(listener);
    _animController.forward(from: 0).whenComplete(() {
      animation.removeListener(listener);
      widget.mapController.rotate(0.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final estAligne = _rotationDeg.abs() < 0.5;

    return Positioned(
      top: 0,
      right: 0,
      child: Padding(
        padding: widget.margin,
        child: AnimatedOpacity(
          opacity: estAligne ? 0.0 : 1.0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: estAligne,
            child: Material(
              color: Colors.white,
              shape: const CircleBorder(),
              elevation: 3,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _recentrerVersLeNord,
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Transform.rotate(
                    angle: -_rotationDeg * (math.pi / 180.0),
                    child: const Icon(
                      Icons.explore,
                      color: Colors.red,
                      size: 26,
                    ),
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