import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'synth.dart';

/// Plays synthesised sounds.
abstract class AudioOut {
  /// Stops the current sound and starts [sound]; completes when it is playing.
  Future<void> play(SynthSound sound);

  Future<void> stop();
}

/// Android: plays the WAV bytes through an AudioTrack in MainActivity.kt (no audio plugin needed).
/// Elsewhere (tests, other platforms) the face animates silently.
class NativeAudioOut implements AudioOut {
  static const _channel = MethodChannel('healthguardians/audio');

  @override
  Future<void> play(SynthSound sound) async {
    try {
      await _channel.invokeMethod<void>('play', {'wav': sound.wav});
    } on MissingPluginException {
      // no native player on this platform
    } on PlatformException catch (e) {
      debugPrint('audio: ${e.code} ${e.message}');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // no native player on this platform
    } on PlatformException catch (e) {
      debugPrint('audio: ${e.code} ${e.message}');
    }
  }
}
