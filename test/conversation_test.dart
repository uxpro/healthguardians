import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:health_guardians/audio/sound_bank.dart';
import 'package:health_guardians/conversation/conversation.dart';
import 'package:health_guardians/conversation/script.dart';
import 'package:health_guardians/face/face_mode.dart';
import 'package:health_guardians/services/event_log.dart';

import 'fakes.dart';

const q1 = 'How are you today?';
const q2 = 'Did you take your daily medication?';
const exercises = 'Let me show you these exercises';
const great = 'Great you did it!';

void main() {
  final bank = SoundBank.build(phrasesOf(checkInScript));
  Duration spoken(String text) => bank.phrase(text).duration + const Duration(milliseconds: 450);

  late FakeAudio audio;
  late LocalEventLog log;
  late Conversation talk;

  setUp(() {
    audio = FakeAudio();
    log = LocalEventLog();
    talk = Conversation(sounds: bank, audio: audio, events: log);
  });

  tearDown(() => talk.dispose());

  testWidgets('the whole check-in: speak, listen, speak, listen, act, speak, idle', (tester) async {
    talk.enterIdle();
    expect(talk.mode, FaceMode.idle);
    unawaited(talk.start());
    await tester.pump();

    expect(talk.running, isTrue);
    expect(talk.mode, FaceMode.speaking);
    expect(talk.caption, q1);
    expect(talk.envelopeNow(), greaterThanOrEqualTo(0));

    await tester.pump(spoken(q1));
    expect(talk.mode, FaceMode.listening);
    expect(talk.asking!.eventType, 'mood_answer');
    talk.answer(talk.asking!.options.first);
    await tester.pump();

    expect(talk.mode, FaceMode.speaking);
    expect(talk.caption, q2);
    await tester.pump(spoken(q2));
    expect(talk.mode, FaceMode.listening);
    talk.answer(const AnswerOption('maybe', 'Maybe')); // not an option: ignored
    await tester.pump();
    expect(talk.mode, FaceMode.listening);
    talk.answer(talk.asking!.options.firstWhere((o) => o.value == 'yes'));
    await tester.pump();

    expect(talk.caption, exercises);
    await tester.pump(spoken(exercises));
    expect(talk.mode, FaceMode.action);
    expect(talk.actionRemaining, const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 5));
    expect(talk.mode, FaceMode.action);
    expect(talk.actionRemaining, const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));

    expect(talk.mode, FaceMode.speaking);
    expect(talk.caption, great);
    await tester.pump(spoken(great));
    expect(talk.mode, FaceMode.idle);
    expect(talk.running, isFalse);
    expect(talk.caption, isNull);

    expect(audio.played, ['idle', q1, 'listening', q2, 'listening', exercises, 'action', 'action', great, 'idle']);
    expect(log.events.map((e) => e.eventType),
        ['session_started', 'mood_answer', 'medication_answer', 'exercise_demo', 'session_completed']);
    expect(log.events.map((e) => e.sessionId).toSet(), {talk.sessionId});
    expect(log.events[1].answer, 'good');
    expect(log.events[1].question, q1);
    expect(log.events[1].mode, 'listening');
    expect(log.events[2].answer, 'yes');
    expect(log.events[3].mode, 'action');
    expect(log.events[3].details['duration_ms'], 10000);
    expect(log.events[4].mode, 'idle');
  });

  testWidgets('no answer within the time limit is logged as no_answer and the check-in goes on', (tester) async {
    unawaited(talk.start());
    await tester.pump(spoken(q1));
    expect(talk.mode, FaceMode.listening);
    await tester.pump(const Duration(seconds: 21));
    expect(talk.mode, FaceMode.speaking);
    expect(talk.caption, q2);
    expect(log.events.last.eventType, 'mood_answer');
    expect(log.events.last.answer, 'no_answer');
    talk.cancel();
  });

  testWidgets('stopping returns to idle and logs nothing more', (tester) async {
    unawaited(talk.start());
    await tester.pump(spoken(q1));
    talk.cancel();
    await tester.pump();
    expect(talk.mode, FaceMode.idle);
    expect(talk.running, isFalse);
    expect(talk.asking, isNull);
    expect(audio.stops, 1);
    await tester.pump(const Duration(seconds: 60));
    expect(log.events.map((e) => e.eventType), ['session_started']);
    // a new check-in can start
    unawaited(talk.start());
    await tester.pump();
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
    expect(log.events.length, 1);
    talk.cancel();
  });

  test('event rows carry no user id (the database takes it from the JWT)', () {
    final row = HgEvent(sessionId: 's', eventType: 'mood_answer', mode: 'listening', question: q1, answer: 'good').toRow();
    expect(row.containsKey('user_id'), isFalse);
    expect(row['answer'], 'good');
    expect(row['client_time'], endsWith('Z'));
  });

  test('session ids are UUID v4', () {
    final id = newUuidV4();
    expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    expect(newUuidV4(), isNot(id));
  });
}
