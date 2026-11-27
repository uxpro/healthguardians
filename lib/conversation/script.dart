/// The demo conversation the face runs through. Nothing is shown on screen: the face speaks the
/// recorded voice clips in assets/voice/ and changes mode in step with them.
library;

sealed class ScriptStep {
  const ScriptStep();
}

/// Idling for [duration] (grey face, resting hum).
class IdleStep extends ScriptStep {
  const IdleStep(this.duration);
  final Duration duration;
}

/// Speaking: plays the recorded clip assets/voice/[voice].wav; the step lasts as long as the clip.
class VoiceStep extends ScriptStep {
  const VoiceStep(this.voice);
  final String voice;
}

/// Listening for [duration] while the patient answers or does something. With [music] the
/// musical interlude plays instead of the listening hum.
class ListenStep extends ScriptStep {
  const ListenStep(this.duration, {this.music = false});
  final Duration duration;
  final bool music;
}

/// Action: the face leads an exercise for [duration]; logged as [eventType].
class ActionStep extends ScriptStep {
  const ActionStep(this.eventType, this.duration);
  final String eventType;
  final Duration duration;
}

/// Back to idling; the session is logged as completed.
class FinishStep extends ScriptStep {
  const FinishStep();
}

/// SPEAKING_1  "Hey young man, why are you in this hospital, how is the day going?"
/// LISTENING   the patient tells how the day is going
/// SPEAKING_2  "You know I don't have to take pills like you ... would you do me the favour?"
/// LISTENING   musical interlude while the patient takes the pill
/// SPEAKING_3  "Oh thanks, now we are talking, c'mon let's go for some stretching, mate!"
/// ACTION      stretching, 10 repetitions
/// SPEAKING_4  "Awesome ... 10 reps! ... see you later, alligator."
/// IDLING
const demoScript = <ScriptStep>[
  IdleStep(Duration(milliseconds: 1200)),
  VoiceStep('speaking_1'),
  ListenStep(Duration(seconds: 4)),
  VoiceStep('speaking_2'),
  ListenStep(Duration(seconds: 10), music: true),
  VoiceStep('speaking_3'),
  ActionStep('exercise_demo', Duration(seconds: 20)),
  VoiceStep('speaking_4'),
  FinishStep(),
];

/// Asset path of a voice clip.
String voiceAsset(String voice) => 'assets/voice/$voice.wav';

/// Voice clips used by [script], in order, without repeats.
List<String> voicesOf(List<ScriptStep> script) => [
      for (final s in script)
        if (s is VoiceStep) s.voice,
    ].toSet().toList();
