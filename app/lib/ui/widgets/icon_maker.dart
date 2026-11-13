import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The icon styles offered when naming a new app.
const List<(String, String)> kIconStyles = [('letter', 'Letter'), ('ring', 'Ring'), ('spark', 'Spark'), ('dots', 'Dots')];

/// A rounded-square app icon: gradient background plus a simple white mark. Used for the live preview
/// and (rendered to PNG) as the launcher icon of the built app.
class AppIconPainter extends CustomPainter {
  final String style;
  final String letter;
  final List<Color> colors;
  const AppIconPainter(this.style, this.letter, this.colors);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectXY(rect, s * 0.22, s * 0.22),
      Paint()..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors).createShader(rect),
    );
    final white = Paint()..color = Colors.white;
    final c = Offset(s / 2, s / 2);
    switch (style) {
      case 'ring':
        canvas.drawCircle(
          c,
          s * 0.22,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = s * 0.08
            ..color = Colors.white,
        );
        canvas.drawCircle(c + Offset(s * 0.21, -s * 0.21), s * 0.065, white);
      case 'spark':
        final path = Path();
        for (var i = 0; i < 8; i++) {
          final a = -math.pi / 2 + i * math.pi / 4;
          final r = i.isEven ? s * 0.30 : s * 0.09;
          final pt = c + Offset(math.cos(a) * r, math.sin(a) * r);
          i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
        }
        canvas.drawPath(path..close(), white);
      case 'dots':
        canvas.drawCircle(c + Offset(0, -s * 0.15), s * 0.095, white);
        canvas.drawCircle(c + Offset(-s * 0.16, s * 0.12), s * 0.095, white);
        canvas.drawCircle(c + Offset(s * 0.16, s * 0.12), s * 0.095, white);
      default:
        final tp = TextPainter(
          text: TextSpan(text: letter.isEmpty ? 'A' : letter.characters.first.toUpperCase(), style: TextStyle(color: Colors.white, fontSize: s * 0.56, fontWeight: FontWeight.w700)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(AppIconPainter o) => o.style != style || o.letter != letter || o.colors != colors;
}

/// The launcher icon as a PNG.
Future<Uint8List> renderIcon(String style, String letter, List<Color> colors, {int size = 512}) async {
  final rec = ui.PictureRecorder();
  AppIconPainter(style, letter, colors).paint(Canvas(rec), Size(size.toDouble(), size.toDouble()));
  final img = await rec.endRecording().toImage(size, size);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  if (data == null) throw StateError('Could not draw the icon.');
  return data.buffer.asUint8List();
}

class IconPreview extends StatelessWidget {
  final String style;
  final String letter;
  final List<Color> colors;
  final double size;
  const IconPreview({super.key, required this.style, required this.letter, required this.colors, this.size = 64});
  @override
  Widget build(BuildContext context) => CustomPaint(size: Size(size, size), painter: AppIconPainter(style, letter, colors));
}
