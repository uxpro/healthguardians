import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:health_guardians/audio/synth.dart';

import 'fakes.dart';

int _u32(Uint8List b, int i) => ByteData.sublistView(b).getUint32(i, Endian.little);
int _u16(Uint8List b, int i) => ByteData.sublistView(b).getUint16(i, Endian.little);
String _tag(Uint8List b, int i) => String.fromCharCodes(b.sublist(i, i + 4));

void main() {
  final bank = testBank();
  final synth = Synth();
  final modeSounds = [bank.listening, bank.interlude, bank.action, bank.idle];

  test('mode sounds last 4 to 10 seconds; the bank holds the clips and the mode sounds', () {
    for (final s in modeSounds) {
      expect(s.seconds, inInclusiveRange(4.0, 10.0), reason: s.name);
    }
    expect(bank.interlude.seconds, 10.0);
    expect(bank.all.length, 4 + 4);
  });

  test('longer phrases last longer', () {
    expect(synth.speech('Did you take your daily medication?').seconds,
        greaterThan(synth.speech('Great you did it!').seconds));
  });

  test('sounds are valid 16-bit mono WAV files', () {
    for (final s in bank.all) {
      final b = s.wav;
      expect(_tag(b, 0), 'RIFF');
      expect(_tag(b, 8), 'WAVE');
      expect(_tag(b, 12), 'fmt ');
      expect(_u16(b, 20), 1, reason: 'PCM');
      expect(_u16(b, 22), 1, reason: 'mono');
      expect(_u32(b, 24), 22050);
      expect(_u16(b, 34), 16);
      expect(_tag(b, 36), 'data');
      expect(_u32(b, 40), b.length - 44);
      expect(_u32(b, 4), b.length - 8);
    }
  });

  test('sounds are audible and not clipped', () {
    for (final s in modeSounds) {
      final pcm = ByteData.sublistView(s.wav, 44);
      var peak = 0;
      for (var i = 0; i + 1 < pcm.lengthInBytes; i += 2) {
        final v = pcm.getInt16(i, Endian.little).abs();
        if (v > peak) peak = v;
      }
      expect(peak, greaterThan(32767 * 0.3), reason: s.name);
      expect(peak, lessThan(32767), reason: s.name);
    }
  });

  test('envelope follows the sound: silent lead-in, loud syllables, pauses between words', () {
    final s = synth.speech('How are you today?');
    expect(s.envelope.length, (s.seconds * 50).ceil());
    expect(s.envelope.reduce((a, b) => a > b ? a : b), closeTo(1.0, 1e-6));
    expect(s.envelopeAt(0.1), lessThan(0.05), reason: 'lead-in');
    var loud = 0, quiet = 0;
    for (var t = 0.4; t < s.seconds - 0.6; t += 0.02) {
      final e = s.envelopeAt(t);
      if (e > 0.5) loud++;
      if (e < 0.1) quiet++;
    }
    expect(loud, greaterThan(20));
    expect(quiet, greaterThan(3), reason: 'gaps between words');
    expect(s.envelopeAt(-1), 0);
    expect(s.envelopeAt(s.seconds + 1), 0);
  });

  test('synthesis is deterministic', () {
    final a = Synth().speech('How are you today?');
    final b = Synth().speech('How are you today?');
    expect(a.wav, b.wav);
    expect(Synth().speech('Great you did it!').wav, isNot(a.wav));
  });

  test('syllables', () {
    expect(Synth.syllableVowels('medication'), ['e', 'i', 'a', 'i']);
    expect(Synth.syllableVowels('take'), ['a']);
    expect(Synth.syllableVowels('today'), ['o', 'a']);
    expect(Synth.syllableVowels('you'), ['o']);
    expect(Synth.syllableVowels('why'), ['i']);
  });
}
