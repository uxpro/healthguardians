import 'package:health_guardians/audio/audio_out.dart';
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
