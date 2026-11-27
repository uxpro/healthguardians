import 'dart:math' as math;
import 'dart:typed_data';

import 'package:health_guardians/audio/audio_out.dart';
import 'package:health_guardians/audio/sound_bank.dart';
import 'package:health_guardians/audio/synth.dart';

/// Records what would be played.
class FakeAudio implements AudioOut {
  final List<String> played = [];
  int stops = 0;

  @override
  Future<void> play(SynthSound sound) async => played.add(sound.name);

  @override
  Future<void> stop() async => stops++;
}

/// A steady 220 Hz tone of [seconds] as a WAV file (stands in for a recorded voice clip).
Uint8List toneWav(double seconds, {int sampleRate = 22050}) {
  final out = Float32List((seconds * sampleRate).round());
  for (var i = 0; i < out.length; i++) {
    out[i] = 0.5 * math.sin(2 * math.pi * 220 * i / sampleRate);
  }
  return encodeWav(out, sampleRate);
}

/// Lengths of the stand-in voice clips used by the tests.
const testVoiceSeconds = {'speaking_1': 1.0, 'speaking_2': 2.0, 'speaking_3': 1.5, 'speaking_4': 1.2};

/// Sound bank with tone clips instead of the recordings, so the timing is known exactly.
SoundBank testBank() => SoundBank.build({for (final e in testVoiceSeconds.entries) e.key: toneWav(e.value)});
