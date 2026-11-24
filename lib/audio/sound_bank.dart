import 'synth.dart';

/// All sounds of a check-in, synthesised once (in a background isolate, see main.dart) so the
/// animation never waits for synthesis.
class SoundBank {
  SoundBank(this._phrases, this.listening, this.action, this.idle);

  final Map<String, SynthSound> _phrases;
  final SynthSound listening;
  final SynthSound action;
  final SynthSound idle;

  /// The spoken phrase for [text] (synthesised now if it was not prepared).
  SynthSound phrase(String text) => _phrases.putIfAbsent(text, () => Synth().speech(text));

  Iterable<SynthSound> get all => [..._phrases.values, listening, action, idle];

  /// Synthesises the phrases [texts] and the mode sounds. Top-level friendly for `compute`.
  static SoundBank build(List<String> texts) {
    final synth = Synth();
    return SoundBank({for (final t in texts) t: synth.speech(t)}, synth.listening(), synth.action(), synth.idle());
  }
}
