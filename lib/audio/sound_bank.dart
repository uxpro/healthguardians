import 'dart:typed_data';

import 'synth.dart';

/// All sounds of the conversation, prepared once (in a background isolate, see main.dart) so the
/// animation never waits: the recorded voice clips plus the synthesised mode sounds.
class SoundBank {
  SoundBank(this._voices, this.listening, this.interlude, this.action, this.idle);

  final Map<String, SynthSound> _voices;
  final SynthSound listening;
  final SynthSound interlude;
  final SynthSound action;
  final SynthSound idle;

  /// The recorded clip [voice] (e.g. "speaking_1").
  SynthSound voice(String voice) =>
      _voices[voice] ?? (throw StateError('voice clip "$voice" is not loaded (assets/voice/$voice.wav)'));

  bool hasVoice(String voice) => _voices.containsKey(voice);

  Iterable<SynthSound> get all => [..._voices.values, listening, interlude, action, idle];

  /// Decodes the voice clips [wavs] (name -> WAV bytes) and synthesises the mode sounds.
  /// Top-level friendly for `compute`.
  static SoundBank build(Map<String, Uint8List> wavs) {
    final synth = Synth();
    return SoundBank(
      {for (final e in wavs.entries) e.key: SynthSound.fromWav(e.key, e.value)},
      synth.listening(),
      synth.interlude(),
      synth.action(),
      synth.idle(),
    );
  }
}
