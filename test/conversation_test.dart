import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:health_guardians/audio/sound_bank.dart';
import 'package:health_guardians/audio/synth.dart';
import 'package:health_guardians/conversation/conversation.dart';
import 'package:health_guardians/conversation/script.dart';
import 'package:health_guardians/face/face_mode.dart';
import 'package:health_guardians/services/event_log.dart';

import 'fakes.dart';

void main() {
  final bank = testBank();
  const gap = Duration(milliseconds: 400); // Conversation.afterSpeech
  Duration spoken(String voice) => bank.voice(voice).duration + gap;

  late FakeAudio audio;
  late LocalEventLog log;
  late Conversation talk;

  setUp(() {
    audio = FakeAudio();
    log = LocalEventLog();
    talk = Conversation(sounds: bank, audio: audio, events: log);
  });

  tearDown(() => talk.dispose());

  testWidgets('the demo runs in time with the clips: idle, speak, listen, speak, interlude, speak, act, speak, idle',
      (tester) async {
    talk.enterIdle();
    unawaited(talk.start());
    await tester.pump();
    expect(talk.running, isTrue);
    expect(talk.mode, FaceMode.idle);

    await tester.pump(const Duration(milliseconds: 1200));
    expect(talk.mode, FaceMode.speaking);
    expect(talk.soundName, 'speaking_1');
    expect(talk.envelopeNow(), greaterThan(0.5), reason: 'the face follows the voice clip');

    await tester.pump(spoken('speaking_1') - const Duration(milliseconds: 1));
    expect(talk.mode, FaceMode.speaking, reason: 'still within the clip and its pause');
    await tester.pump(const Duration(milliseconds: 1));
    expect(talk.mode, FaceMode.listening);
    expect(talk.soundName, 'listening');

    await tester.pump(const Duration(seconds: 4));
    expect(talk.mode, FaceMode.speaking);
    expect(talk.soundName, 'speaking_2');

    await tester.pump(spoken('speaking_2'));
    expect(talk.mode, FaceMode.listening);
    expect(talk.soundName, 'interlude');
    await tester.pump(const Duration(seconds: 9));
    expect(talk.mode, FaceMode.listening, reason: 'the interlude lasts 10 s');
    await tester.pump(const Duration(seconds: 1));
    expect(talk.mode, FaceMode.speaking);
    expect(talk.soundName, 'speaking_3');

    await tester.pump(spoken('speaking_3'));
    expect(talk.mode, FaceMode.action);
    await tester.pump(const Duration(seconds: 19));
    expect(talk.mode, FaceMode.action, reason: 'the stretching lasts 20 s');
    await tester.pump(const Duration(seconds: 1));
    expect(talk.mode, FaceMode.speaking);
    expect(talk.soundName, 'speaking_4');

    await tester.pump(spoken('speaking_4'));
    expect(talk.mode, FaceMode.idle);
    expect(talk.running, isFalse);

    expect(audio.played, [
      'idle', 'idle', 'speaking_1', 'listening', 'speaking_2', 'interlude', 'speaking_3', //
      'action', 'action', 'action', 'action', 'speaking_4', 'idle',
    ]);
    expect(log.events.map((e) => e.eventType), ['session_started', 'exercise_demo', 'session_completed']);
    expect(log.events.map((e) => e.sessionId).toSet(), {talk.sessionId});
    expect(log.events[1].mode, 'action');
    expect(log.events[1].details['duration_ms'], 20000);
    expect(log.events.every((e) => e.question == null && e.answer == null), isTrue);

    // nothing runs afterwards by itself
    await tester.pump(const Duration(minutes: 2));
    expect(talk.runs, 1);
    expect(audio.played.length, 13);
  });

  test('script length is the sum of the steps', () {
    final expected = const Duration(milliseconds: 1200) +
        spoken('speaking_1') +
        const Duration(seconds: 4) +
        spoken('speaking_2') +
        const Duration(seconds: 10) +
        spoken('speaking_3') +
        const Duration(seconds: 20) +
        spoken('speaking_4');
    final t = Conversation(sounds: bank, audio: FakeAudio(), events: LocalEventLog());
    expect(t.scriptLength, expected);
    t.dispose();
  });

  testWidgets('stopping returns to idle and logs nothing more', (tester) async {
    unawaited(talk.start());
    await tester.pump(const Duration(milliseconds: 1200) + spoken('speaking_1') + const Duration(seconds: 5));
    expect(talk.soundName, 'speaking_2');
    talk.cancel();
    await tester.pump();
    expect(talk.mode, FaceMode.idle);
    expect(talk.running, isFalse);
    expect(audio.stops, 1);
    await tester.pump(const Duration(minutes: 2));
    expect(log.events.map((e) => e.eventType), ['session_started']);
    // it can run again
    unawaited(talk.start());
    await tester.pump(const Duration(milliseconds: 1200));
    expect(talk.mode, FaceMode.speaking);
    expect(log.events.where((e) => e.eventType == 'session_started').length, 2);
    talk.cancel();
  });

  testWidgets('start while running does nothing', (tester) async {
    unawaited(talk.start());
    await tester.pump();
    final id = talk.sessionId;
    unawaited(talk.start());
    await tester.pump();
    expect(talk.sessionId, id);
    expect(talk.runs, 1);
    expect(log.events.length, 1);
    talk.cancel();
  });

  test('the demo script uses the four recorded clips, in order', () {
    expect(voicesOf(demoScript), ['speaking_1', 'speaking_2', 'speaking_3', 'speaking_4']);
    expect(demoScript.first, isA<IdleStep>());
    expect(demoScript.last, isA<FinishStep>());
    expect(voiceAsset('speaking_1'), 'assets/voice/speaking_1.wav');
  });

  test('the recorded clips are in the assets, declared in pubspec.yaml, and decode', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('- assets/voice/'));
    final wavs = <String, Uint8List>{
      for (final v in voicesOf(demoScript)) v: File(voiceAsset(v)).readAsBytesSync(),
    };
    final real = SoundBank.build(wavs);
    for (final v in voicesOf(demoScript)) {
      final clip = real.voice(v);
      expect(clip.seconds, inInclusiveRange(2.0, 20.0), reason: v);
      expect(clip.sampleRate, 22050, reason: v);
      expect(clip.envelope.reduce((a, b) => a > b ? a : b), closeTo(1.0, 1e-6), reason: v);
    }
    // speaking_2 is the long one (about 15 s)
    expect(real.voice('speaking_2').seconds, greaterThan(real.voice('speaking_4').seconds));
  });

  test('a missing clip is a clear error', () {
    expect(bank.hasVoice('speaking_9'), isFalse);
    expect(() => bank.voice('speaking_9'), throwsStateError);
  });

  test('event rows carry no user id (the database takes it from the JWT)', () {
    final row = HgEvent(sessionId: 's', eventType: 'exercise_demo', mode: 'action').toRow();
    expect(row.containsKey('user_id'), isFalse);
    expect(row.containsKey('answer'), isFalse);
    expect(row['client_time'], endsWith('Z'));
  });

  test('session ids are UUID v4', () {
    final id = newUuidV4();
    expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    expect(newUuidV4(), isNot(id));
  });

  group('decodeWav', () {
    test('reads back what encodeWav wrote', () {
      final s = Float32List.fromList([0, 0.5, -0.5, 0.25]);
      final (out, rate) = decodeWav(encodeWav(s, 16000));
      expect(rate, 16000);
      expect(out.length, 4);
      for (var i = 0; i < 4; i++) {
        expect(out[i], closeTo(s[i], 1e-3));
      }
    });

    test('skips extra chunks and mixes stereo down to mono', () {
      // RIFF header, a LIST chunk, fmt (stereo), data with two frames
      final b = BytesBuilder();
      void str(String s) => b.add(s.codeUnits);
      void u32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
      void u16(int v) => b.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
      void i16(int v) => b.add((ByteData(2)..setInt16(0, v, Endian.little)).buffer.asUint8List());
      str('RIFF');
      u32(0);
      str('WAVE');
      str('LIST');
      u32(3);
      b.add([1, 2, 3, 0]); // odd length + pad byte
      str('fmt ');
      u32(16);
      u16(1);
      u16(2);
      u32(8000);
      u32(8000 * 4);
      u16(4);
      u16(16);
      str('data');
      u32(8);
      i16(16384);
      i16(0);
      i16(-16384);
      i16(-16384);
      final (out, rate) = decodeWav(b.toBytes());
      expect(rate, 8000);
      expect(out, [closeTo(0.25, 1e-4), closeTo(-0.5, 1e-4)]);
    });

    test('rejects other formats', () {
      expect(() => decodeWav(Uint8List.fromList(List.filled(100, 0x49))), throwsFormatException);
    });
  });
}
