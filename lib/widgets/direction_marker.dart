import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Marqueur de position de l'utilisateur : cercle bordé avec une flèche
/// dont la pointe indique [capDegres] (0° = nord).
///
/// Partagé par la carte principale et l'écran "Mes anecdotes".
class DirectionMarker extends StatelessWidget {
  final double capDegres;
  final Color color;
  final double size;

  const DirectionMarker({
    super.key,
    required this.capDegres,
    this.color = Colors.blue,
    this.size = 48,
  });

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: capDegres * (math.pi / 180.0),
      child: CustomPaint(
        size: Size(size, size),
        painter: DirectionMarkerPainter(color: color),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Painter : cercle blanc bordé de bleu avec flèche directionnelle
// La pointe de la flèche pointe vers le haut (= nord = 0°).
// La rotation est appliquée par Transform.rotate dans DirectionMarker.
// ---------------------------------------------------------------------------
class DirectionMarkerPainter extends CustomPainter {
  final Color color;
  const DirectionMarkerPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = const Color(0x33FFFFFF) // blanc très légèrement translucide
        ..style = PaintingStyle.fill,
    );

    canvas.drawCircle(center, radius,
        Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 3);

    final double h = radius * 1.1;
    final double w = radius * 0.50;

    final ui.Path path = ui.Path();
    path.moveTo(center.dx, center.dy - h * 0.56);
    path.lineTo(center.dx - w, center.dy + h * 0.36);
    path.lineTo(center.dx, center.dy + h * 0.16);
    path.lineTo(center.dx + w, center.dy + h * 0.36);
    path.close();

    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(DirectionMarkerPainter old) => old.color != color;
}