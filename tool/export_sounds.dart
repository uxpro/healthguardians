// Writes the synthesised mode sounds as WAV files to build_sounds/, to listen to them on the PC:
//   dart run tool/export_sounds.dart
// (The voice clips are already WAV files in assets/voice/.)
import 'dart:io';

import 'package:health_guardians/audio/synth.dart';

void main() {
  final synth = Synth();
  final sounds = [synth.listening(), synth.interlude(), synth.action(), synth.idle()];
  final dir = Directory('build_sounds')..createSync(recursive: true);
  for (final s in sounds) {
    final file = File('${dir.path}/${s.name}.wav')..writeAsBytesSync(s.wav);
    stdout.writeln('${file.path}  ${s.seconds.toStringAsFixed(1)} s');
  }
}
