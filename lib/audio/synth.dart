import 'dart:math' as math;
import 'dart:typed_data';

/// A sound synthesised in code: 16-bit mono WAV bytes plus a loudness envelope that drives the
/// face animation while the sound plays.
class SynthSound {
  SynthSound._(this.name, this.sampleRate, this.wav, this.envelope);

  /// Builds the WAV file and the envelope from samples in -1..1.
  factory SynthSound.fromSamples(String name, Float32List samples, int sampleRate) {
    return SynthSound._(name, sampleRate, encodeWav(samples, sampleRate), computeEnvelope(samples, sampleRate));
  }

  /// Decodes a recorded clip (16-bit PCM WAV, mono or stereo) so it plays and animates like the
  /// synthesised sounds. Throws [FormatException] for anything else.
  factory SynthSound.fromWav(String name, Uint8List wav) {
    final (samples, rate) = decodeWav(wav);
    return SynthSound.fromSamples(name, samples, rate);
  }

  final String name;
  final int sampleRate;

  /// Complete WAV file (RIFF, PCM 16-bit, mono).
  final Uint8List wav;

  /// Loudness per [envelopeFrame] window, 0..1 (1 = loudest window of this sound).
  final Float32List envelope;

  static const Duration envelopeFrame = Duration(milliseconds: 20);

  int get sampleCount => (wav.length - 44) ~/ 2;
  Duration get duration => Duration(microseconds: sampleCount * 1000000 ~/ sampleRate);
  double get seconds => sampleCount / sampleRate;

  /// Loudness at [t] seconds after the start; 0 before the start and after the end.
  double envelopeAt(double t) {
    if (t < 0 || envelope.isEmpty) return 0;
    final i = (t * 1000 / envelopeFrame.inMilliseconds).floor();
    if (i >= envelope.length) return 0;
    return envelope[i];
  }
}

/// RIFF/WAVE, PCM 16-bit mono. Samples are clamped to -1..1.
Uint8List encodeWav(Float32List samples, int sampleRate) {
  final data = samples.length * 2;
  final b = ByteData(44 + data);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  b.setUint32(4, 36 + data, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  b.setUint32(16, 16, Endian.little); // fmt chunk size
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 1, Endian.little); // mono
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * 2, Endian.little); // byte rate
  b.setUint16(32, 2, Endian.little); // block align
  b.setUint16(34, 16, Endian.little); // bits per sample
  tag(36, 'data');
  b.setUint32(40, data, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    final v = samples[i].clamp(-1.0, 1.0);
    b.setInt16(44 + i * 2, (v * 32767).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

/// Samples (-1..1, stereo mixed down to mono) and sample rate of a 16-bit PCM WAV file. Skips
/// extra chunks (LIST and the like) before the data.
(Float32List, int) decodeWav(Uint8List wav) {
  final b = ByteData.sublistView(wav);
  String tag(int at) => String.fromCharCodes(wav.sublist(at, at + 4));
  if (wav.length < 44 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
    throw const FormatException('not a WAV file');
  }
  var channels = 0, rate = 0, bits = 0;
  var pos = 12;
  while (pos + 8 <= wav.length) {
    final id = tag(pos);
    final len = b.getUint32(pos + 4, Endian.little);
    final body = pos + 8;
    if (id == 'fmt ') {
      if (body + 16 > wav.length || b.getUint16(body, Endian.little) != 1) {
        throw const FormatException('only PCM WAV files are supported');
      }
      channels = b.getUint16(body + 2, Endian.little);
      rate = b.getUint32(body + 4, Endian.little);
      bits = b.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      if (rate <= 0 || bits != 16 || (channels != 1 && channels != 2)) {
        throw const FormatException('only 16-bit mono or stereo PCM');
      }
      final bytes = math.min(len, wav.length - body);
      final frames = bytes ~/ (2 * channels);
      final out = Float32List(frames);
      for (var f = 0; f < frames; f++) {
        var v = 0.0;
        for (var c = 0; c < channels; c++) {
          v += b.getInt16(body + (f * channels + c) * 2, Endian.little) / 32768;
        }
        out[f] = v / channels;
      }
      return (out, rate);
    }
    pos = body + len + (len & 1);
  }
  throw const FormatException('WAV file has no data chunk');
}

/// RMS per 20 ms window, normalised so the loudest window is 1.
Float32List computeEnvelope(Float32List samples, int sampleRate) {
  final frame = sampleRate * SynthSound.envelopeFrame.inMilliseconds ~/ 1000;
  final n = (samples.length + frame - 1) ~/ frame;
  final env = Float32List(n);
  var peak = 0.0;
  for (var f = 0; f < n; f++) {
    final start = f * frame;
    final end = math.min(start + frame, samples.length);
    var sum = 0.0;
    for (var i = start; i < end; i++) {
      sum += samples[i] * samples[i];
    }
    final rms = math.sqrt(sum / (end - start));
    env[f] = rms;
    if (rms > peak) peak = rms;
  }
  if (peak > 0) {
    for (var f = 0; f < n; f++) {
      env[f] = env[f] / peak;
    }
  }
  return env;
}

/// Sounds of the face, all generated in code, 4-8 seconds each.
class Synth {
  Synth({this.sampleRate = 22050});

  final int sampleRate;

  static const double minSeconds = 4;
  static const double maxSeconds = 8;

  /// Length of the spoken phrase: grows with the text, between 4 and 8 seconds.
  static double speechSeconds(String text) =>
      (1.6 + 0.12 * text.length).clamp(minSeconds, maxSeconds).toDouble();

  /// Vowel formants (F1, F2, F3 in Hz).
  static const Map<String, List<double>> _formants = {
    'a': [730, 1090, 2440],
    'e': [530, 1840, 2480],
    'i': [270, 2290, 3010],
    'o': [570, 840, 2410],
    'u': [300, 870, 2240],
  };

  static int _seed(String s) {
    var h = 17;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h;
  }

  /// Splits a word into syllable vowels, e.g. "medication" -> [e, i, a, i].
  static List<String> syllableVowels(String word) {
    final groups = RegExp('[aeiouy]+').allMatches(word).map((m) => m.group(0)!).toList();
    // a silent final "e" ("take", "these") is not a syllable of its own
    if (groups.length > 1 && word.endsWith('e') && groups.last == 'e' && !word.endsWith('le')) {
      groups.removeLast();
    }
    if (groups.isEmpty) return const ['a'];
    return groups.map((g) {
      final v = g[0] == 'y' ? (g.length > 1 ? g[1] : 'i') : g[0];
      return v == 'y' ? 'i' : v;
    }).toList();
  }

  /// A robotic voice speaking [text]: one formant-shaped buzz per syllable, with pauses between
  /// words, falling pitch, and a rise at the end of a question. Deterministic for a given text.
  SynthSound speech(String text) {
    final rnd = math.Random(_seed(text));
    final seconds = speechSeconds(text);
    final out = Float32List((seconds * sampleRate).round());
    final words = text
        .toLowerCase()
        .replaceAll(RegExp("[^a-z' ]"), ' ')
        .split(' ')
        .where((w) => w.trim().isNotEmpty)
        .toList();
    if (words.isEmpty) return SynthSound.fromSamples(text, out, sampleRate);
    final syllables = [for (final w in words) syllableVowels(w)];
    final total = syllables.fold<int>(0, (a, s) => a + s.length);
    const lead = 0.30, tail = 0.45, wordGap = 0.09;
    final usable = seconds - lead - tail - wordGap * (words.length - 1);
    final syl = usable / total;
    final question = text.trim().endsWith('?');
    final baseF0 = 150.0 + rnd.nextDouble() * 20;

    var t = lead;
    var k = 0; // syllable index over the whole phrase
    for (var w = 0; w < words.length; w++) {
      final word = words[w];
      final lastWord = w == words.length - 1;
      for (var s = 0; s < syllables[w].length; s++) {
        final progress = k / math.max(1, total - 1);
        var f0 = baseF0 * (1 - 0.12 * progress) * (1 + (rnd.nextDouble() - 0.5) * 0.12);
        if (s == 0) f0 *= 1.06; // stress on the first syllable of a word
        final rise = question && lastWord ? 0.35 * (s + 1) / syllables[w].length : 0.0;
        final consonant = s == 0 ? !'aeiou'.contains(word[0]) : true;
        _syllable(out, t, syl * 0.92, f0, f0 * (1 + rise), _formants[syllables[w][s]]!, consonant, rnd);
        t += syl;
        k++;
      }
      t += wordGap;
    }
    _robotise(out);
    _normalise(out, 0.85);
    return SynthSound.fromSamples(text, out, sampleRate);
  }

  void _syllable(Float32List out, double start, double length, double f0Start, double f0End,
      List<double> formants, bool consonant, math.Random rnd) {
    final i0 = (start * sampleRate).round();
    final n = (length * sampleRate).round();
    final meanF0 = (f0Start + f0End) / 2;
    final harmonics = math.max(1, math.min(24, (4000 / meanF0).floor()));
    // harmonic amplitudes shaped by the vowel's formants
    final amp = List<double>.filled(harmonics + 1, 0);
    for (var h = 1; h <= harmonics; h++) {
      final f = h * meanF0;
      var a = 0.04 / h;
      for (var j = 0; j < formants.length; j++) {
        final bw = 120.0 + 60 * j;
        final d = (f - formants[j]) / bw;
        a += (j == 0 ? 1.0 : 0.6 / j) * math.exp(-d * d);
      }
      amp[h] = a;
    }
    var phase = 0.0;
    const attack = 0.02, release = 0.05;
    for (var i = 0; i < n && i0 + i < out.length; i++) {
      final ts = i / sampleRate;
      final p = i / n;
      final f0 = f0Start + (f0End - f0Start) * p;
      phase += 2 * math.pi * f0 / sampleRate;
      var v = 0.0;
      for (var h = 1; h <= harmonics; h++) {
        v += amp[h] * math.sin(h * phase);
      }
      final env = math.min(1.0, ts / attack) * math.min(1.0, (length - ts) / release) * (1 - 0.25 * p);
      out[i0 + i] += (v * env * 0.25).toDouble();
    }
    if (consonant) {
      // short noise burst before the vowel, like a plosive or fricative
      final burst = (0.022 * sampleRate).round();
      var prev = 0.0;
      for (var i = 0; i < burst && i0 + i < out.length; i++) {
        final r = rnd.nextDouble() * 2 - 1;
        final hp = r - prev; // crude high-pass
        prev = r;
        out[i0 + i] += hp * 0.12 * (1 - i / burst);
      }
    }
  }

  /// Ring modulation and a little bit-crushing: the "robot" timbre.
  void _robotise(Float32List out) {
    for (var i = 0; i < out.length; i++) {
      final t = i / sampleRate;
      final ring = 0.78 + 0.22 * math.sin(2 * math.pi * 70 * t);
      final v = out[i] * ring;
      final crushed = (v * 24).round() / 24;
      out[i] = 0.75 * v + 0.25 * crushed;
    }
  }

  /// Listening: an upward two-tone chirp, then a soft breathing hum (4 s).
  SynthSound listening() {
    const seconds = 4.0;
    final out = Float32List((seconds * sampleRate).round());
    final rnd = math.Random(7);
    var ph = 0.0;
    for (var i = 0; i < out.length; i++) {
      final t = i / sampleRate;
      var v = 0.0;
      if (t < 0.36) {
        final f = t < 0.16 ? 520.0 : 780.0 + 400 * (t - 0.16);
        ph += 2 * math.pi * f / sampleRate;
        final local = t < 0.16 ? t : t - 0.18;
        final e = local < 0 ? 0.0 : math.sin(math.pi * math.min(1.0, local / 0.16));
        v += 0.55 * math.sin(ph) * e;
      }
      final breath = 0.5 + 0.5 * math.sin(2 * math.pi * 1.1 * t - math.pi / 2);
      final fade = math.min(1.0, t / 0.4) * math.min(1.0, (seconds - t) / 0.8);
      v += fade * breath * (0.22 * math.sin(2 * math.pi * 220 * t) + 0.12 * math.sin(2 * math.pi * 330 * t) +
          0.03 * (rnd.nextDouble() * 2 - 1));
      out[i] = v;
    }
    _normalise(out, 0.7);
    return SynthSound.fromSamples('listening', out, sampleRate);
  }

  /// Action: a calm chord that swells and fades in a slow organic rhythm (5 s, played twice for
  /// the 10 s exercise demo).
  SynthSound action() {
    const seconds = 5.0;
    final out = Float32List((seconds * sampleRate).round());
    const chord = [196.0, 246.94, 293.66, 392.0];
    for (var i = 0; i < out.length; i++) {
      final t = i / sampleRate;
      final pulse = 0.55 + 0.3 * math.sin(2 * math.pi * 0.4 * t - math.pi / 2) + 0.15 * math.sin(2 * math.pi * 0.23 * t);
      final fade = math.min(1.0, t / 0.3) * math.min(1.0, (seconds - t) / 0.3);
      var v = 0.0;
      for (var c = 0; c < chord.length; c++) {
        v += math.sin(2 * math.pi * chord[c] * t + c) / (c + 1);
      }
      out[i] = v * pulse * fade;
    }
    _normalise(out, 0.6);
    return SynthSound.fromSamples('action', out, sampleRate);
  }

  /// Musical interlude (10 s): a light, cheerful melody over a soft chord pad, played while the
  /// patient takes the pill.
  SynthSound interlude() {
    const seconds = 10.0;
    const beat = 0.5; // seconds per note
    final out = Float32List((seconds * sampleRate).round());
    // C major pentatonic tune (Hz), one note per beat; 0 = rest
    const tune = [
      523.25, 659.25, 783.99, 659.25, 587.33, 659.25, 523.25, 0.0, //
      587.33, 659.25, 783.99, 880.0, 783.99, 659.25, 587.33, 0.0, //
      523.25, 587.33, 659.25, 783.99, //
    ];
    const chords = [
      [261.63, 329.63, 392.0], // C
      [293.66, 349.23, 440.0], // Dm
      [261.63, 329.63, 392.0], // C
      [246.94, 293.66, 392.0], // G
      [261.63, 329.63, 392.0], // C
    ];
    for (var i = 0; i < out.length; i++) {
      final t = i / sampleRate;
      final fade = math.min(1.0, t / 0.3) * math.min(1.0, (seconds - t) / 1.0);
      // pad: one chord per 2 s, gently swelling
      final chord = chords[math.min(chords.length - 1, t ~/ 2)];
      final swell = 0.6 + 0.4 * math.sin(math.pi * ((t % 2) / 2));
      var pad = 0.0;
      for (final f in chord) {
        pad += math.sin(2 * math.pi * f / 2 * t);
      }
      // melody: bell-like notes that decay
      final n = t ~/ beat;
      var bell = 0.0;
      if (n < tune.length && tune[n] > 0) {
        final f = tune[n];
        final local = t - n * beat;
        final env = math.min(1.0, local / 0.01) * math.exp(-local * 5);
        bell = env * (math.sin(2 * math.pi * f * local) + 0.3 * math.sin(4 * math.pi * f * local));
      }
      out[i] = (0.18 * pad * swell + 0.9 * bell) * fade;
    }
    _normalise(out, 0.6);
    return SynthSound.fromSamples('interlude', out, sampleRate);
  }

  /// Idle: a quiet low hum pulsing slowly, like a resting energy beam (4 s).
  SynthSound idle() {
    const seconds = 4.0;
    final out = Float32List((seconds * sampleRate).round());
    for (var i = 0; i < out.length; i++) {
      final t = i / sampleRate;
      final pulse = 0.6 + 0.4 * math.sin(2 * math.pi * 0.25 * t - math.pi / 2);
      final fade = math.min(1.0, t / 0.6) * math.min(1.0, (seconds - t) / 0.8);
      final v = math.sin(2 * math.pi * 55 * t) + 0.6 * math.sin(2 * math.pi * 110 * t) + 0.25 * math.sin(2 * math.pi * 165 * t);
      out[i] = v * pulse * fade;
    }
    _normalise(out, 0.35);
    return SynthSound.fromSamples('idle', out, sampleRate);
  }

  static void _normalise(Float32List out, double peak) {
    var max = 0.0;
    for (final v in out) {
      if (v.abs() > max) max = v.abs();
    }
    if (max == 0) return;
    final g = peak / max;
    for (var i = 0; i < out.length; i++) {
      out[i] = out[i] * g;
    }
  }
}
