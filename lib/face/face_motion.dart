import 'dart:math' as math;

import 'face_mode.dart';

/// Position, size and visibility of one eye (a cluster of geometric shapes).
/// [x] is the horizontal centre as a fraction of the screen width.
class EyePose {
  const EyePose(this.x, this.scale, this.alpha);

  final double x;
  final double scale;
  final double alpha;

  static EyePose lerp(EyePose a, EyePose b, double t) =>
      EyePose(_lerp(a.x, b.x, t), _lerp(a.scale, b.scale, t), _lerp(a.alpha, b.alpha, t));
}

/// How the virtual wave travels through the shapes and changes their size.
enum WaveKind {
  /// from the sides towards the centre (speaking)
  inward,

  /// from the centre towards the sides (listening)
  outward,

  /// slowly from left to right (idling)
  sweep,

  /// no travelling wave: each shape breathes on its own slow rhythm (action)
  organic,
}

/// Everything the painter needs for one frame.
class FaceFrame {
  const FaceFrame({
    required this.mode,
    required this.palette,
    required this.left,
    required this.right,
    required this.merged,
    required this.eyeY,
    required this.wave,
    required this.waveAmp,
    required this.time,
    required this.aura,
    required this.beam,
    required this.flash,
    required this.envelope,
  });

  final FaceMode mode;
  final FacePalette palette;

  /// Left eye, right eye, and the bigger shape both form when they meet in the centre.
  final EyePose left, right, merged;

  /// Vertical centre of the eyes as a fraction of the screen height.
  final double eyeY;

  final WaveKind wave;

  /// Size change caused by the wave: 0.3 means shapes grow and shrink by up to 30 %.
  final double waveAmp;

  /// Seconds since the face started (drives the wave).
  final double time;

  /// Intensity of the translucent aura layer, 0..1.
  final double aura;

  /// Intensity of the idle energy beam, 0..1.
  final double beam;

  /// Bright flash when the eyes collide (speaking) or burst apart (listening), 0..1.
  final double flash;

  /// Smoothed loudness of the current sound, 0..1.
  final double envelope;

  List<EyePose> get eyes => [left, right, merged];

  /// Size factor of a shape whose centre is at [cellX] (fraction of the screen width).
  /// [seed] (0..1) gives each shape its own rhythm in the organic action mode.
  double cellScale(double cellX, double seed) {
    final d = (cellX - 0.5).abs();
    final s = switch (wave) {
      WaveKind.inward => math.sin(2 * math.pi * (6.5 * d + 1.6 * time)),
      WaveKind.outward => math.sin(2 * math.pi * (6.5 * d - 1.3 * time)),
      WaveKind.sweep => math.sin(2 * math.pi * (4.0 * cellX - 0.35 * time)),
      WaveKind.organic =>
        0.6 * math.sin(2 * math.pi * (0.28 * time + seed)) + 0.4 * math.sin(2 * math.pi * (0.17 * time + 2 * seed)),
    };
    return math.max(0.25, 1 + waveAmp * s);
  }
}

enum _Seg { atSides, closing, merged, opening }

/// The motion of the face, independent of drawing so it can be tested.
///
/// - Idling: grey eyes rest apart and drift slightly from side to side; an energy beam pulses at a
///   low frequency; a slow wave sweeps through the shapes.
/// - Speaking: blue eyes move from the sides to the centre, collide into one bigger shape for
///   800 ms, then rewind to the sides; speed, wave and aura follow the loudness of the sound.
/// - Listening: the same animation in reverse direction (purple): the eyes burst apart from the
///   centre to the sides, stay wide for 800 ms, and rewind to the centre; the wave runs outward.
/// - Action: calm yellow eyes at rest; every shape grows and shrinks on its own slow, organic pulse.
class FaceMotion {
  static const double sideX = 0.2;
  static const double centerX = 0.5;
  static const double restLeftX = 0.34;
  static const double restRightX = 0.66;
  static const double eyeY = 0.46;

  /// Time to move between the sides and the centre at normal speed.
  static const double moveSeconds = 1.0;

  /// The emphasised pose holds this long: merged in the centre (speaking), wide at the sides (listening).
  static const double holdSeconds = 0.8;

  /// Short rest at the other end of the movement.
  static const double restSeconds = 0.25;

  /// Cross-fade between modes.
  static const double blendSeconds = 0.45;

  /// Merged shape size relative to one eye.
  static const double mergedScale = 1.6;

  FaceMode _mode = FaceMode.idle;
  double _clock = 0;
  double _modeTime = 0;
  double _env = 0;
  _Seg _seg = _Seg.atSides;
  double _segTime = 0;
  double _p = 0; // 0 = eyes at the sides, 1 = eyes in the centre
  FaceFrame? _last;
  FaceFrame? _from;

  FaceMode get mode => _mode;

  /// Current movement position: 0 = at the sides, 1 = in the centre.
  double get progress => _p;

  void setMode(FaceMode mode) {
    if (mode == _mode) return;
    _from = _last;
    _mode = mode;
    _modeTime = 0;
    _segTime = 0;
    if (mode == FaceMode.listening) {
      _seg = _Seg.merged; // listening starts in the centre and opens outward
      _p = 1;
    } else {
      _seg = _Seg.atSides; // speaking starts at the sides and closes inward
      _p = 0;
    }
  }

  /// Advances by [dt] seconds; [envelope] is the loudness (0..1) of the sound playing now.
  FaceFrame tick(double dt, double envelope) {
    dt = dt.clamp(0.0, 0.1).toDouble();
    _clock += dt;
    _modeTime += dt;
    final target = envelope.clamp(0.0, 1.0).toDouble();
    final rate = target > _env ? 18.0 : 5.0; // fast attack, slow release
    _env += (target - _env) * (1 - math.exp(-rate * dt));

    var frame = _target(dt);
    final from = _from;
    if (from != null && _modeTime < blendSeconds) {
      final b = _easeInOut(_modeTime / blendSeconds);
      frame = FaceFrame(
        mode: frame.mode,
        palette: FacePalette.lerp(from.palette, frame.palette, b),
        left: EyePose.lerp(from.left, frame.left, b),
        right: EyePose.lerp(from.right, frame.right, b),
        merged: EyePose.lerp(from.merged, frame.merged, b),
        eyeY: frame.eyeY,
        wave: frame.wave,
        waveAmp: _lerp(from.waveAmp, frame.waveAmp, b),
        time: frame.time,
        aura: _lerp(from.aura, frame.aura, b),
        beam: _lerp(from.beam, frame.beam, b),
        flash: _lerp(from.flash, frame.flash, b),
        envelope: frame.envelope,
      );
    } else {
      _from = null;
    }
    _last = frame;
    return frame;
  }

  FaceFrame _target(double dt) {
    if (_mode == FaceMode.idle) return _idle();
    if (_mode == FaceMode.action) return _action();
    _advanceCycle(dt); // speaking and listening
    return _cycleFrame();
  }

  FaceFrame _idle() {
    final drift = 0.035 * math.sin(2 * math.pi * 0.06 * _clock) + 0.01 * math.sin(2 * math.pi * 0.17 * _clock);
    final beam = 0.55 + 0.45 * math.sin(2 * math.pi * 0.22 * _clock);
    return FaceFrame(
      mode: _mode,
      palette: FacePalette.idle,
      left: EyePose(restLeftX + drift, 1, 1),
      right: EyePose(restRightX + drift, 1, 1),
      merged: EyePose(centerX + drift, 1, 0),
      eyeY: eyeY,
      wave: WaveKind.sweep,
      waveAmp: 0.05 + 0.05 * beam,
      time: _clock,
      aura: 0.2 + 0.15 * beam + 0.3 * _env,
      beam: beam,
      flash: 0,
      envelope: _env,
    );
  }

  FaceFrame _action() {
    final breath = 0.5 + 0.5 * math.sin(2 * math.pi * 0.35 * _clock);
    return FaceFrame(
      mode: _mode,
      palette: FacePalette.action,
      left: const EyePose(restLeftX, 1, 1),
      right: const EyePose(restRightX, 1, 1),
      merged: const EyePose(centerX, 1, 0),
      eyeY: eyeY,
      wave: WaveKind.organic,
      waveAmp: 0.22 + 0.08 * breath,
      time: _clock,
      aura: 0.25 + 0.2 * breath + 0.25 * _env,
      beam: 0,
      flash: 0,
      envelope: _env,
    );
  }

  /// Listening keeps a gentle pulse when its sound has ended, so the face still looks attentive.
  double get _cycleEnv {
    if (_mode != FaceMode.listening) return _env;
    return math.max(_env, 0.15 + 0.1 * math.sin(2 * math.pi * 0.8 * _clock));
  }

  double _holdAt(_Seg seg) {
    final speaking = _mode == FaceMode.speaking;
    if (seg == _Seg.merged) return speaking ? holdSeconds : restSeconds;
    return speaking ? restSeconds : holdSeconds; // atSides
  }

  _Seg _next(_Seg seg) => switch (seg) {
        _Seg.atSides => _Seg.closing,
        _Seg.closing => _Seg.merged,
        _Seg.merged => _Seg.opening,
        _Seg.opening => _Seg.atSides,
      };

  void _advanceCycle(double dt) {
    final speed = (0.6 + 0.8 * _cycleEnv) / moveSeconds;
    var left = dt;
    // a large dt may finish a segment and continue in the next one
    for (var guard = 0; guard < 4 && left > 0; guard++) {
      switch (_seg) {
        case _Seg.atSides:
        case _Seg.merged:
          final remaining = _holdAt(_seg) - _segTime;
          if (left < remaining) {
            _segTime += left;
            left = 0;
          } else {
            left -= math.max(0.0, remaining);
            _enter(_next(_seg));
          }
          break;
        case _Seg.closing:
          final toCentre = (1 - _p) / speed;
          if (left < toCentre) {
            _p += left * speed;
            _segTime += left;
            left = 0;
          } else {
            left -= toCentre;
            _p = 1;
            _enter(_Seg.merged);
          }
          break;
        case _Seg.opening:
          final toSides = _p / speed;
          if (left < toSides) {
            _p -= left * speed;
            _segTime += left;
            left = 0;
          } else {
            left -= toSides;
            _p = 0;
            _enter(_Seg.atSides);
          }
          break;
      }
    }
  }

  void _enter(_Seg seg) {
    _seg = seg;
    _segTime = 0;
    if (seg == _Seg.merged) _p = 1;
    if (seg == _Seg.atSides) _p = 0;
  }

  FaceFrame _cycleFrame() {
    final speaking = _mode == FaceMode.speaking;
    final env = _cycleEnv;
    final e = _easeInOut(_p);
    final m = _seg == _Seg.merged ? 1.0 : _smoothstep(0.75, 1.0, _p);

    // the collision (speaking) or the burst apart (listening) flashes and bounces
    var flash = 0.0;
    var bounce = 0.0;
    if (speaking && _seg == _Seg.merged) {
      flash = math.exp(-4 * _segTime);
      bounce = 0.12 * math.exp(-5 * _segTime) * math.sin(16 * _segTime);
    } else if (!speaking && _seg == _Seg.opening) {
      flash = math.exp(-4 * _segTime);
    }
    // listening: eyes open wider at the sides (the mirror of the bigger merged shape)
    final sideScale = speaking ? 1.0 : 1 + 0.15 * (1 - e);

    return FaceFrame(
      mode: _mode,
      palette: speaking ? FacePalette.speaking : FacePalette.listening,
      left: EyePose(_lerp(sideX, centerX, e), sideScale, 1 - m),
      right: EyePose(_lerp(1 - sideX, centerX, e), sideScale, 1 - m),
      merged: EyePose(centerX, _lerp(1, mergedScale, m) * (1 + bounce), m),
      eyeY: eyeY,
      wave: speaking ? WaveKind.inward : WaveKind.outward,
      waveAmp: speaking ? 0.12 + 0.38 * env : 0.10 + 0.30 * env,
      time: _clock,
      aura: 0.2 + 0.8 * env,
      beam: 0,
      flash: flash,
      envelope: env,
    );
  }
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

double _easeInOut(double t) {
  t = t.clamp(0.0, 1.0).toDouble();
  return t < 0.5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3).toDouble() / 2;
}

double _smoothstep(double e0, double e1, double x) {
  final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0).toDouble();
  return t * t * (3 - 2 * t);
}
