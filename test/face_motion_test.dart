import 'package:flutter_test/flutter_test.dart';
import 'package:health_guardians/face/face_mode.dart';
import 'package:health_guardians/face/face_motion.dart';
import 'package:health_guardians/face/face_painter.dart';

const dt = 1 / 60;

/// Runs [seconds] of animation and returns every frame.
List<FaceFrame> run(FaceMotion m, double seconds, {double envelope = 0.5}) =>
    [for (var t = 0.0; t < seconds; t += dt) m.tick(dt, envelope)];

void main() {
  test('idle: grey, eyes apart with only a small drift, pulsing beam, slow sweeping wave', () {
    final m = FaceMotion();
    final frames = run(m, 20, envelope: 0);
    final xs = frames.map((f) => f.left.x).toList();
    final drift = xs.reduce((a, b) => a > b ? a : b) - xs.reduce((a, b) => a < b ? a : b);
    expect(drift, greaterThan(0.02));
    expect(drift, lessThan(0.12));
    expect(frames.last.palette.core, FacePalette.idle.core);
    expect(frames.every((f) => f.merged.alpha == 0 && f.left.alpha == 1), isTrue);
    final beams = frames.map((f) => f.beam);
    expect(beams.reduce((a, b) => a < b ? a : b), lessThan(0.2));
    expect(beams.reduce((a, b) => a > b ? a : b), greaterThan(0.9));
    expect(frames.last.wave, WaveKind.sweep);
  });

  test('speaking: eyes move from the sides to the centre, merge for 800 ms, then rewind', () {
    final m = FaceMotion();
    run(m, 1);
    m.setMode(FaceMode.speaking);
    final frames = run(m, 6, envelope: 0.5);
    final after = frames.skip(30).toList(); // after the cross-fade
    expect(after.first.left.x, closeTo(FaceMotion.sideX, 0.03));
    expect(after.first.right.x, closeTo(1 - FaceMotion.sideX, 0.03));
    // merged phases: one bigger shape in the centre, held for 800 ms
    final mergedRuns = <int>[];
    var runLength = 0;
    for (final f in after) {
      if (f.merged.alpha == 1 && f.left.alpha == 0) {
        runLength++;
        expect(f.merged.x, 0.5);
        expect(f.merged.scale, greaterThan(1.4));
      } else if (runLength > 0) {
        mergedRuns.add(runLength);
        runLength = 0;
      }
    }
    expect(mergedRuns, isNotEmpty);
    expect(mergedRuns.first * dt, closeTo(FaceMotion.holdSeconds, 0.05));
    // the collision flashes
    expect(after.map((f) => f.flash).reduce((a, b) => a > b ? a : b), greaterThan(0.9));
    // and the eyes come back to the sides
    final firstMerge = after.indexWhere((f) => f.merged.alpha == 1);
    expect(after.skip(firstMerge).any((f) => (f.left.x - FaceMotion.sideX).abs() < 0.01), isTrue);
    expect(after.last.palette.core, FacePalette.speaking.core);
    expect(after.last.wave, WaveKind.inward);
  });

  test('speaking follows the sound: louder moves faster and grows the wave and aura', () {
    double timeToMerge(double env) {
      final m = FaceMotion()..setMode(FaceMode.speaking);
      var t = 0.0;
      while (m.tick(dt, env).merged.alpha < 1) {
        t += dt;
      }
      return t;
    }

    expect(timeToMerge(1.0), lessThan(timeToMerge(0.0)));
    final quiet = (FaceMotion()..setMode(FaceMode.speaking));
    final loud = (FaceMotion()..setMode(FaceMode.speaking));
    final q = run(quiet, 1, envelope: 0).last;
    final l = run(loud, 1, envelope: 1).last;
    expect(l.waveAmp, greaterThan(q.waveAmp));
    expect(l.aura, greaterThan(q.aura));
  });

  test('listening: purple, starts in the centre and opens towards the sides', () {
    final m = FaceMotion();
    run(m, 1);
    m.setMode(FaceMode.listening);
    expect(m.progress, 1, reason: 'starts merged in the centre');
    final frames = run(m, 4, envelope: 0);
    final after = frames.skip(30).toList();
    // first movement is outward: distance between the eyes grows before it shrinks
    final firstOpen = after.indexWhere((f) => f.left.alpha > 0.5);
    expect(firstOpen, greaterThanOrEqualTo(0));
    final wideAt = after.indexWhere((f) => (f.left.x - FaceMotion.sideX).abs() < 0.01);
    expect(wideAt, greaterThan(firstOpen));
    expect(after[wideAt].left.scale, greaterThan(1.1), reason: 'eyes open wider at the sides');
    expect(after.last.palette.core, FacePalette.listening.core);
    expect(after.last.wave, WaveKind.outward);
    // without sound it keeps moving (attentive pulse)
    expect(after.map((f) => f.left.x).toSet().length, greaterThan(10));
  });

  test('action: calm yellow, eyes at rest, each shape pulses on its own rhythm', () {
    final m = FaceMotion()..setMode(FaceMode.action);
    final frames = run(m, 6, envelope: 0.3);
    final f = frames.last;
    expect(f.palette.core, FacePalette.action.core);
    expect(f.left.x, FaceMotion.restLeftX);
    expect(f.wave, WaveKind.organic);
    final scales = [for (final s in FacePainter.seeds) f.cellScale(0.3, s)];
    expect(scales.toSet().length, greaterThan(5), reason: 'shapes differ');
    for (final frame in frames) {
      for (final s in FacePainter.seeds) {
        final v = frame.cellScale(0.3, s);
        expect(v, inInclusiveRange(0.6, 1.4));
      }
    }
  });

  test('waves travel inward when speaking and outward when listening', () {
    FaceFrame at(FaceMode mode, double time) =>
        FaceFrame(
          mode: mode,
          palette: FacePalette.of(mode),
          left: const EyePose(0.3, 1, 1),
          right: const EyePose(0.7, 1, 1),
          merged: const EyePose(0.5, 1, 0),
          eyeY: 0.5,
          wave: mode == FaceMode.speaking ? WaveKind.inward : WaveKind.outward,
          waveAmp: 0.3,
          time: time,
          aura: 0,
          beam: 0,
          flash: 0,
          envelope: 0,
        );
    // follow a crest: where is the biggest shape on the left half at two moments?
    double crest(FaceFrame f) {
      var best = 0.0, bestX = 0.0;
      for (var x = 0.40; x <= 0.48; x += 0.0005) {
        final s = f.cellScale(x, 0);
        if (s > best) {
          best = s;
          bestX = x;
        }
      }
      return bestX;
    }

    // at t=0 a crest sits at d = 0.25/6.5 from the centre (x ~ 0.4615); 20 ms later it has moved
    final s0 = crest(at(FaceMode.speaking, 0)), s1 = crest(at(FaceMode.speaking, 0.02));
    expect(s1, greaterThan(s0), reason: 'left half: crest moves right, towards the centre');
    final l0 = crest(at(FaceMode.listening, 0)), l1 = crest(at(FaceMode.listening, 0.02));
    expect(l1, lessThan(l0), reason: 'left half: crest moves left, towards the side');
  });

  test('mode changes cross-fade instead of jumping', () {
    final m = FaceMotion();
    final before = run(m, 1).last;
    m.setMode(FaceMode.speaking);
    final next = m.tick(dt, 0.5);
    expect((next.left.x - before.left.x).abs(), lessThan(0.02));
    expect(next.palette.core, isNot(FacePalette.speaking.core));
  });

  test('a long frame (app paused) does not break the cycle', () {
    final m = FaceMotion()..setMode(FaceMode.speaking);
    for (var i = 0; i < 50; i++) {
      final f = m.tick(5, 1);
      expect(f.left.x, inInclusiveRange(FaceMotion.sideX - 1e-9, 0.5 + 1e-9));
      expect(m.progress, inInclusiveRange(0, 1));
    }
  });

  test('eye lattice is an oval honeycomb', () {
    expect(FacePainter.lattice.length, inInclusiveRange(20, 30));
    final width = FacePainter.lattice.map((o) => o.dx.abs()).reduce((a, b) => a > b ? a : b);
    final height = FacePainter.lattice.map((o) => o.dy.abs()).reduce((a, b) => a > b ? a : b);
    expect(width, greaterThan(height));
  });
}
