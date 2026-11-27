import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_guardians/face/face_view.dart';
import 'package:health_guardians/screens/face_screen.dart';
import 'package:health_guardians/services/event_log.dart';

import 'fakes.dart';

void main() {
  final bank = testBank();
  const gap = Duration(milliseconds: 400);
  // idle 1.2 s, clips + pauses, listening 4 s, interlude 10 s, stretching 20 s
  final demoLength = const Duration(milliseconds: 1200) +
      const Duration(seconds: 34) +
      [for (final v in testVoiceSeconds.keys) bank.voice(v).duration + gap].reduce((a, b) => a + b);

  void landscape(WidgetTester tester) {
    tester.view.physicalSize = const Size(2400, 1080);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
  }

  testWidgets('demo: starts once by itself, shows no text, cannot be restarted by tapping', (tester) async {
    landscape(tester);
    final audio = FakeAudio();
    final log = LocalEventLog();
    await tester.pumpWidget(MaterialApp(
      home: FaceScreen(sounds: bank, audio: audio, events: log, autoStart: true, onSignOut: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(log.events.map((e) => e.eventType), ['session_started'], reason: 'started without a tap');
    expect(find.byType(Text), findsNothing);
    expect(find.byTooltip('Stop'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1200));
    expect(audio.played.last, 'speaking_1');
    expect(find.byType(Text), findsNothing, reason: 'nothing of what is said is written on screen');

    // a tap neither restarts nor skips
    await tester.tapAt(tester.getCenter(find.byType(FaceView)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(log.events.where((e) => e.eventType == 'session_started').length, 1);

    for (var t = Duration.zero; t < demoLength; t += const Duration(seconds: 1)) {
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(Text), findsNothing);
    }
    await tester.pump(const Duration(seconds: 1));
    expect(log.events.map((e) => e.eventType), ['session_started', 'exercise_demo', 'session_completed']);
    expect(audio.played.last, 'idle');
    expect(find.byTooltip('Stop'), findsNothing);

    await tester.tapAt(tester.getCenter(find.byType(FaceView)));
    await tester.pump(const Duration(seconds: 5));
    expect(log.events.length, 3, reason: 'runs once');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('signed in: tap the face to start; only the event status line is written', (tester) async {
    landscape(tester);
    final audio = FakeAudio();
    final log = LocalEventLog();
    await tester.pumpWidget(MaterialApp(
      home: FaceScreen(sounds: bank, audio: audio, events: log, accountLabel: 'nc@hg.com', onSignOut: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(log.events, isEmpty, reason: 'waits for a tap');
    expect(find.byType(Text), findsOneWidget);
    expect(find.byKey(const Key('event-status')), findsOneWidget);

    await tester.tapAt(tester.getCenter(find.byType(FaceView)));
    await tester.pump(const Duration(milliseconds: 1300));
    expect(audio.played.last, 'speaking_1');
    expect(find.byType(Text), findsOneWidget);

    // stop button ends the conversation
    await tester.tap(find.byTooltip('Stop'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byTooltip('Stop'), findsNothing);
    expect(audio.stops, 1);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the face paints on small and odd screen sizes', (tester) async {
    for (final size in const [Size(800, 360), Size(1280, 800), Size(360, 800)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(MaterialApp(
        home: FaceScreen(sounds: bank, audio: FakeAudio(), events: LocalEventLog(), autoStart: true),
      ));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
    tester.view.reset();
  });
}
