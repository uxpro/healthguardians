// Writes the synthesised sounds as WAV files to build_sounds/, to listen to them on the PC:
//   dart run tool/export_sounds.dart
import 'dart:io';

import 'package:health_guardians/audio/sound_bank.dart';
import 'package:health_guardians/conversation/script.dart';

void main() {
  final bank = SoundBank.build(phrasesOf(checkInScript));
  final dir = Directory('build_sounds')..createSync(recursive: true);
  for (final s in bank.all) {
    final name = s.name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_|_$'), '');
    final file = File('${dir.path}/$name.wav')..writeAsBytesSync(s.wav);
    stdout.writeln('${file.path}  ${s.seconds.toStringAsFixed(1)} s');
  }
}
