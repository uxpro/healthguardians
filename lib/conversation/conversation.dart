import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../audio/audio_out.dart';
import '../audio/sound_bank.dart';
import '../audio/synth.dart';
import '../face/face_mode.dart';
import '../services/event_log.dart';
import 'script.dart';

class _Cancelled implements Exception {
  const _Cancelled();
}

/// Runs the demo script: switches the face mode in step with the recorded voice clips, plays the
/// sounds and logs the session. Shows nothing on screen and waits for no input: every step has a
/// fixed length (a voice step lasts as long as its clip).
class Conversation extends ChangeNotifier {
  Conversation({
    required this.sounds,
    required this.audio,
    required this.events,
    this.script = demoScript,
    this.afterSpeech = const Duration(milliseconds: 400),
  });

  final SoundBank sounds;
  final AudioOut audio;
  final EventSink events;
  final List<ScriptStep> script;

  /// Pause after a voice clip before the next step.
  final Duration afterSpeech;

  FaceMode _mode = FaceMode.idle;
  String? _sessionId;
  bool _running = false;
  bool _disposed = false;
  int _runs = 0;

  SynthSound? _sound;
  final Stopwatch _soundClock = Stopwatch();

  int _generation = 0;
  Timer? _timer;
  Completer<void>? _wake;

  FaceMode get mode => _mode;
  String? get sessionId => _sessionId;
  bool get running => _running;

  /// How many times the script was started.
  int get runs => _runs;

  /// Name of the sound playing now (voice clip or mode sound), else null.
  String? get soundName => _sound?.name;

  /// Loudness of the sound playing now (0..1): drives the animation.
  double envelopeNow() {
    final s = _sound;
    if (s == null) return 0;
    return s.envelopeAt(_soundClock.elapsedMicroseconds / 1e6);
  }

  /// Total length of the script without the pauses after speech.
  Duration get scriptLength {
    var total = Duration.zero;
    for (final step in script) {
      total += switch (step) {
        IdleStep(:final duration) => duration,
        VoiceStep(:final voice) => sounds.voice(voice).duration + afterSpeech,
        ListenStep(:final duration) => duration,
        ActionStep(:final duration) => duration,
        FinishStep() => Duration.zero,
      };
    }
    return total;
  }

  /// Idle face with its resting hum (when the screen opens).
  void enterIdle() {
    _setMode(FaceMode.idle);
    _play(sounds.idle);
  }

  /// Starts the script. Does nothing if it is running.
  Future<void> start() async {
    if (_running || _disposed) return;
    _running = true;
    _runs++;
    final gen = ++_generation;
    _sessionId = newUuidV4();
    _log('session_started', FaceMode.idle);
    notifyListeners();
    try {
      for (final step in script) {
        _check(gen);
        await _run(step, gen);
      }
    } on _Cancelled {
      return;
    } finally {
      if (gen == _generation) {
        _running = false;
        _notify();
      }
    }
  }

  /// Stops the script and returns to idling.
  void cancel() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
    _running = false;
    _sound = null;
    _setMode(FaceMode.idle);
    unawaited(audio.stop());
  }

  @override
  void dispose() {
    cancel();
    _disposed = true;
    super.dispose();
  }

  // ---------------------------------------------------------------- steps

  Future<void> _run(ScriptStep step, int gen) async {
    switch (step) {
      case IdleStep(:final duration):
        _setMode(FaceMode.idle);
        await _playFor(sounds.idle, duration, gen);
      case VoiceStep(:final voice):
        _setMode(FaceMode.speaking);
        final clip = sounds.voice(voice);
        _play(clip);
        await _sleep(clip.duration + afterSpeech, gen);
      case ListenStep(:final duration, :final music):
        _setMode(FaceMode.listening);
        await _playFor(music ? sounds.interlude : sounds.listening, duration, gen);
      case ActionStep(:final eventType, :final duration):
        _setMode(FaceMode.action);
        await _playFor(sounds.action, duration, gen);
        _log(eventType, FaceMode.action, details: {'duration_ms': duration.inMilliseconds, 'completed': true});
      case FinishStep():
        _setMode(FaceMode.idle);
        _play(sounds.idle);
        _log('session_completed', FaceMode.idle, details: {'steps': script.length});
    }
  }

  // ---------------------------------------------------------------- helpers

  void _check(int gen) {
    if (gen != _generation || _disposed) throw const _Cancelled();
  }

  Future<void> _sleep(Duration d, int gen) async {
    final wake = Completer<void>();
    _wake = wake;
    _timer = Timer(d, () {
      if (!wake.isCompleted) wake.complete();
    });
    await wake.future;
    _check(gen);
  }

  /// Plays [sound] for [total], starting it again whenever it ends.
  Future<void> _playFor(SynthSound sound, Duration total, int gen) async {
    var left = total;
    while (left > Duration.zero) {
      _play(sound);
      final chunk = sound.duration > Duration.zero && sound.duration < left ? sound.duration : left;
      await _sleep(chunk, gen);
      left -= chunk;
    }
  }

  void _play(SynthSound sound) {
    _sound = sound;
    _soundClock
      ..reset()
      ..start();
    audio.play(sound).then((_) {
      // restart the clock when playback has really started, so the face follows the sound
      if (identical(_sound, sound)) {
        _soundClock
          ..reset()
          ..start();
      }
    }, onError: (Object e) => debugPrint('audio: $e'));
  }

  void _log(String type, FaceMode mode, {Map<String, Object?> details = const {}}) {
    final id = _sessionId;
    if (id == null) return;
    unawaited(events.log(HgEvent(sessionId: id, eventType: type, mode: mode.name, details: details)));
  }

  void _setMode(FaceMode m) {
    _mode = m;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}

/// Random UUID (version 4) for the session id.
String newUuidV4([math.Random? random]) {
  final rnd = random ?? math.Random.secure();
  final b = List<int>.generate(16, (_) => rnd.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
