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

/// Runs the check-in script: switches the face mode, plays the sounds, waits for answers and
/// logs one event per step.
class Conversation extends ChangeNotifier {
  Conversation({
    required this.sounds,
    required this.audio,
    required this.events,
    this.script = checkInScript,
    this.listenTimeout = const Duration(seconds: 20),
    this.afterSpeech = const Duration(milliseconds: 400),
  });

  final SoundBank sounds;
  final AudioOut audio;
  final EventSink events;
  final List<ScriptStep> script;

  /// No answer within this time is logged as "no_answer".
  final Duration listenTimeout;

  /// Pause after a phrase before the next step.
  final Duration afterSpeech;

  FaceMode _mode = FaceMode.idle;
  String? _caption;
  AskStep? _asking;
  ActionStep? _acting;
  Duration _actionRemaining = Duration.zero;
  String? _sessionId;
  bool _running = false;
  bool _disposed = false;

  SynthSound? _sound;
  final Stopwatch _soundClock = Stopwatch();

  int _generation = 0;
  Timer? _timer;
  Completer<void>? _wake;
  Completer<AnswerOption?>? _answer;

  FaceMode get mode => _mode;

  /// Text shown under the face: the phrase being spoken, the question, or the exercise.
  String? get caption => _caption;

  /// The question waiting for an answer (listening mode), else null.
  AskStep? get asking => _asking;

  /// The exercise running (action mode), else null.
  ActionStep? get acting => _acting;
  Duration get actionRemaining => _actionRemaining;
  String? get sessionId => _sessionId;
  bool get running => _running;

  /// Loudness of the sound playing now (0..1): drives the animation.
  double envelopeNow() {
    final s = _sound;
    if (s == null) return 0;
    return s.envelopeAt(_soundClock.elapsedMicroseconds / 1e6);
  }

  /// Idle face with its resting hum (when the screen opens).
  void enterIdle() {
    _setMode(FaceMode.idle);
    _play(sounds.idle);
  }

  /// Starts a check-in. Does nothing if one is running.
  Future<void> start() async {
    if (_running || _disposed) return;
    _running = true;
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

  /// Answer from the buttons shown in listening mode.
  void answer(AnswerOption option) {
    final pending = _answer;
    final asking = _asking;
    if (pending == null || pending.isCompleted || asking == null) return;
    if (!asking.options.contains(option)) return;
    pending.complete(option);
  }

  /// Stops the check-in and returns to idling.
  void cancel() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
    final pending = _answer;
    if (pending != null && !pending.isCompleted) pending.complete(null);
    _running = false;
    _asking = null;
    _acting = null;
    _caption = null;
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
      case final SayStep say:
        _asking = null;
        _acting = null;
        _caption = say.text;
        _setMode(FaceMode.speaking);
        final sound = sounds.phrase(say.text);
        _play(sound);
        await _sleep(sound.duration + afterSpeech, gen);
      case final AskStep ask:
        _asking = ask;
        _caption = ask.question;
        _setMode(FaceMode.listening);
        _play(sounds.listening);
        final asked = DateTime.now();
        final chosen = await _waitForAnswer(gen);
        _asking = null;
        _log(ask.eventType, FaceMode.listening, question: ask.question, answer: chosen?.value ?? 'no_answer', details: {
          if (chosen != null) 'label': chosen.label,
          'response_ms': DateTime.now().difference(asked).inMilliseconds,
        });
        _notify();
      case final ActionStep act:
        _acting = act;
        _caption = act.caption;
        _setMode(FaceMode.action);
        final seconds = act.duration.inSeconds;
        final loop = sounds.action.duration.inSeconds;
        for (var i = 0; i < seconds; i++) {
          if (loop > 0 && i % loop == 0) _play(sounds.action);
          _actionRemaining = Duration(seconds: seconds - i);
          _notify();
          await _sleep(const Duration(seconds: 1), gen);
        }
        _actionRemaining = Duration.zero;
        _acting = null;
        _log(act.eventType, FaceMode.action, details: {'duration_ms': act.duration.inMilliseconds, 'completed': true});
        _notify();
      case FinishStep():
        _caption = null;
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

  Future<AnswerOption?> _waitForAnswer(int gen) async {
    final pending = Completer<AnswerOption?>();
    _answer = pending;
    _timer = Timer(listenTimeout, () {
      if (!pending.isCompleted) pending.complete(null);
    });
    final chosen = await pending.future;
    _timer?.cancel();
    _answer = null;
    _check(gen);
    return chosen;
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

  void _log(String type, FaceMode mode, {String? question, String? answer, Map<String, Object?> details = const {}}) {
    final id = _sessionId;
    if (id == null) return;
    unawaited(events.log(HgEvent(
      sessionId: id,
      eventType: type,
      mode: mode.name,
      question: question,
      answer: answer,
      details: details,
    )));
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
