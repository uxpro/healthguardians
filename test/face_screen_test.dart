import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_guardians/audio/sound_bank.dart';
import 'package:health_guardians/conversation/script.dart';
import 'package:health_guardians/face/face_view.dart';
import 'package:health_guardians/screens/face_screen.dart';
import 'package:health_guardians/services/event_log.dart';

import 'fakes.dart';

void main() {
  final bank = SoundBank.build(phrasesOf(checkInScript));

  testWidgets('tap the face, answer with the buttons, the face keeps animating', (tester) async {
    tester.view.physicalSize = const Size(2400, 1080);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    final log = LocalEventLog();
    await tester.pumpWidget(MaterialApp(home: FaceScreen(sounds: bank, audio: FakeAudio(), events: log)));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Tap the face to start the check-in'), findsOneWidget);
    expect(find.text('Not signed in: events are not saved'), findsOneWidget);

    await tester.tapAt(tester.getCenter(find.byType(FaceView)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('How are you today?'), findsOneWidget);
    expect(find.byKey(const Key('answer-good')), findsNothing);

    await tester.pump(bank.phrase('How are you today?').duration + const Duration(milliseconds: 500));
    expect(find.byKey(const Key('answer-good')), findsOneWidget);
    await tester.tap(find.byKey(const Key('answer-not_good')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Did you take your daily medication?'), findsOneWidget);
    expect(log.events.last.answer, 'not_good');

    // stop button ends the check-in
    await tester.tap(find.byTooltip('Stop the check-in'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Tap the face to start the check-in'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the face paints on small and odd screen sizes', (tester) async {
    for (final size in const [Size(800, 360), Size(1280, 800), Size(360, 800)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(MaterialApp(home: FaceScreen(sounds: bank, audio: FakeAudio(), events: LocalEventLog())));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(tester.takeException(), isNull);
    }
    tester.view.reset();
    await tester.pumpWidget(const SizedBox());
  });
}
