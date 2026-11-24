import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'face_motion.dart';

/// Draws the face: on black, each eye is a honeycomb of hexagons whose solid colour fades out
/// towards their edges; a translucent aura glows behind them, and an energy beam pulses when idling.
class FacePainter extends CustomPainter {
  FacePainter(this.frame) : super(repaint: frame);

  final ValueListenable<FaceFrame> frame;

  /// Centres of the shapes of one eye, in units of the shape spacing (an oval honeycomb).
  static final List<Offset> lattice = buildLattice();

  /// Per-shape rhythm offset (0..1) for the organic action pulse.
  static final List<double> seeds = [
    for (var i = 0; i < lattice.length; i++) (math.sin(i * 12.9898) * 43758.5453).abs() % 1.0,
  ];

  /// Half-width of an eye in units of the shape spacing.
  static const double eyeHalfWidth = 3.1;

  static List<Offset> buildLattice() {
    final out = <Offset>[];
    final h = math.sqrt(3) / 2;
    for (var r = -4; r <= 4; r++) {
      for (var q = -6; q <= 6; q++) {
        final x = q + r / 2;
        final y = r * h;
        final nx = x / (eyeHalfWidth * 0.98), ny = y / 2.05;
        if (nx * nx + ny * ny <= 1.0) out.add(Offset(x, y));
      }
    }
    return out;
  }

  /// Pointy-top hexagon with circumradius 1.
  static final Path _hexagon = () {
    final p = Path();
    for (var i = 0; i < 6; i++) {
      final a = math.pi / 6 + i * math.pi / 3;
      final v = Offset(math.cos(a), math.sin(a));
      if (i == 0) {
        p.moveTo(v.dx, v.dy);
      } else {
        p.lineTo(v.dx, v.dy);
      }
    }
    return p..close();
  }();

  static Color _alpha(Color c, double a) => c.withAlpha((a.clamp(0.0, 1.0) * 255).round());

  @override
  void paint(Canvas canvas, Size size) {
    final f = frame.value;
    final w = size.width, h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF000000));
    if (w <= 0 || h <= 0) return;

    // spacing of the shapes: eyes fill about 40 % of the height
    final unit = math.min(h * 0.062, w * 0.031);
    final cy = f.eyeY * h;
    final core = f.palette.core;
    final aura = f.palette.aura;

    // ---- aura: translucent glow behind the shapes, stronger with louder sound
    final glow = Paint()..blendMode = BlendMode.plus;
    final screenGlow = 0.05 + 0.10 * f.aura;
    glow.shader = ui.Gradient.radial(Offset(w / 2, cy), w * 0.55,
        [_alpha(aura, screenGlow), _alpha(aura, 0)], const [0.0, 1.0]);
    canvas.drawRect(Offset.zero & size, glow);
    for (final eye in f.eyes) {
      if (eye.alpha <= 0.01) continue;
      final c = Offset(eye.x * w, cy);
      final r = eyeHalfWidth * unit * eye.scale * (1.7 + 0.6 * f.aura);
      final a = eye.alpha * (0.12 + 0.38 * f.aura);
      glow.shader = ui.Gradient.radial(c, r, [_alpha(aura, a), _alpha(aura, a * 0.35), _alpha(aura, 0)], const [0.0, 0.45, 1.0]);
      canvas.drawCircle(c, r, glow);
    }

    // ---- idle energy beam: a long thin glow through the eyes
    if (f.beam > 0.01) {
      _beam(canvas, Offset(w / 2, cy), w * 0.46, h * 0.03 * (0.7 + 0.6 * f.beam), aura, 0.55 * f.beam);
      _beam(canvas, Offset(w / 2, cy), w * 0.40, h * 0.008 * (0.7 + 0.6 * f.beam), core, 0.9 * f.beam);
    }

    // ---- the shapes: size changes as the wave passes through them
    final shape = Paint();
    for (final eye in f.eyes) {
      if (eye.alpha <= 0.01) continue;
      shape.shader = ui.Gradient.radial(Offset.zero, 1.0,
          [_alpha(core, eye.alpha), _alpha(core, eye.alpha * 0.85), _alpha(core, 0)], const [0.0, 0.5, 1.0]);
      final step = unit * eye.scale;
      for (var i = 0; i < lattice.length; i++) {
        final o = lattice[i];
        final x = eye.x * w + o.dx * step;
        final y = cy + o.dy * step;
        final radius = step * 0.6 * f.cellScale(x / w, seeds[i]);
        canvas.save();
        canvas.translate(x, y);
        canvas.scale(radius);
        canvas.drawPath(_hexagon, shape);
        canvas.restore();
      }
    }

    // ---- collision / burst flash
    if (f.flash > 0.01) {
      final c = Offset(w / 2, cy);
      final r = eyeHalfWidth * unit * FaceMotion.mergedScale * 1.4;
      final flash = Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.Gradient.radial(c, r,
            [_alpha(const Color(0xFFFFFFFF), 0.45 * f.flash), _alpha(aura, 0.25 * f.flash), _alpha(aura, 0)], const [0.0, 0.4, 1.0]);
      canvas.drawCircle(c, r, flash);
    }
  }

  /// Elliptical glow: a circle with a radial gradient, stretched horizontally.
  void _beam(Canvas canvas, Offset centre, double halfLength, double halfThickness, Color color, double alpha) {
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.scale(halfLength / halfThickness, 1);
    final p = Paint()
      ..blendMode = BlendMode.plus
      ..shader = ui.Gradient.radial(Offset.zero, halfThickness,
          [_alpha(color, alpha), _alpha(color, alpha * 0.4), _alpha(color, 0)], const [0.0, 0.35, 1.0]);
    canvas.drawCircle(Offset.zero, halfThickness, p);
    canvas.restore();
  }

  @override
  bool shouldRepaint(FacePainter oldDelegate) => oldDelegate.frame != frame;
}
