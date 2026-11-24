/// The daily check-in the face runs through.
library;

class AnswerOption {
  const AnswerOption(this.value, this.label);

  /// Stored in the event log.
  final String value;

  /// Shown on the answer button.
  final String label;
}

sealed class ScriptStep {
  const ScriptStep();
}

/// Speaking mode: the face says [text].
class SayStep extends ScriptStep {
  const SayStep(this.text);
  final String text;
}

/// Listening mode: waits for an answer to [question] and logs it as [eventType].
class AskStep extends ScriptStep {
  const AskStep(this.eventType, this.question, this.options);
  final String eventType;
  final String question;
  final List<AnswerOption> options;
}

/// Action mode: the exercise demo runs for [duration] and is logged as [eventType].
class ActionStep extends ScriptStep {
  const ActionStep(this.eventType, this.caption, this.duration);
  final String eventType;
  final String caption;
  final Duration duration;
}

/// Back to idling; the session is logged as completed.
class FinishStep extends ScriptStep {
  const FinishStep();
}

const checkInScript = <ScriptStep>[
  SayStep('How are you today?'),
  AskStep('mood_answer', 'How are you today?', [
    AnswerOption('good', 'Good'),
    AnswerOption('okay', 'Okay'),
    AnswerOption('not_good', 'Not so good'),
  ]),
  SayStep('Did you take your daily medication?'),
  AskStep('medication_answer', 'Did you take your daily medication?', [
    AnswerOption('yes', 'Yes'),
    AnswerOption('no', 'No'),
  ]),
  SayStep('Let me show you these exercises'),
  ActionStep('exercise_demo', 'Exercise demo: slowly raise both arms, then lower them', Duration(seconds: 10)),
  SayStep('Great you did it!'),
  FinishStep(),
];

/// Texts the face speaks in [script].
List<String> phrasesOf(List<ScriptStep> script) => [
      for (final s in script)
        if (s is SayStep) s.text,
    ];
