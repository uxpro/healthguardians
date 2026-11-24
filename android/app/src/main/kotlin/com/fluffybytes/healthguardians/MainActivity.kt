package com.fluffybytes.healthguardians

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Plays the WAV sounds the app synthesises in Dart (lib/audio/synth.dart) through an AudioTrack,
 * so no audio plugin is needed. Channel "healthguardians/audio":
 *   play(wav: ByteArray)  stops the current sound and starts this one; returns when it is playing
 *   stop()                stops the current sound
 */
class MainActivity : FlutterActivity() {
    private var track: AudioTrack? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The face stays on screen during a check-in.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "healthguardians/audio")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "play" -> {
                        val wav = call.argument<ByteArray>("wav")
                        if (wav == null) {
                            result.error("bad_args", "wav is missing", null)
                        } else {
                            try {
                                play(wav)
                                result.success(null)
                            } catch (e: Exception) {
                                result.error("play_failed", e.message, null)
                            }
                        }
                    }
                    "stop" -> {
                        stopTrack()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        stopTrack()
        super.onDestroy()
    }

    private fun play(wav: ByteArray) {
        stopTrack()
        val pcm = Wav.parse(wav)
        val channelMask = if (pcm.channels == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        val format = AudioFormat.Builder()
            .setSampleRate(pcm.sampleRate)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setChannelMask(channelMask)
            .build()
        val t = AudioTrack(attributes, format, pcm.length, AudioTrack.MODE_STATIC, AudioManager.AUDIO_SESSION_ID_GENERATE)
        val written = t.write(pcm.bytes, pcm.offset, pcm.length)
        if (written < 0) {
            t.release()
            throw IllegalStateException("AudioTrack.write failed: $written")
        }
        t.play()
        track = t
    }

    private fun stopTrack() {
        val t = track ?: return
        track = null
        try {
            if (t.playState != AudioTrack.PLAYSTATE_STOPPED) t.stop()
        } catch (e: IllegalStateException) {
            // already stopped
        }
        t.release()
    }
}

/** The PCM data inside a 16-bit WAV file. */
class Wav(val bytes: ByteArray, val offset: Int, val length: Int, val sampleRate: Int, val channels: Int) {
    companion object {
        private fun le16(b: ByteArray, i: Int) = (b[i].toInt() and 0xff) or ((b[i + 1].toInt() and 0xff) shl 8)
        private fun le32(b: ByteArray, i: Int) = le16(b, i) or (le16(b, i + 2) shl 16)
        private fun tag(b: ByteArray, i: Int) = String(b, i, 4, Charsets.US_ASCII)

        fun parse(b: ByteArray): Wav {
            require(b.size >= 44 && tag(b, 0) == "RIFF" && tag(b, 8) == "WAVE") { "not a WAV file" }
            var channels = 0
            var sampleRate = 0
            var bits = 0
            var pos = 12
            while (pos + 8 <= b.size) {
                val id = tag(b, pos)
                val len = le32(b, pos + 4)
                val body = pos + 8
                if (id == "fmt ") {
                    require(le16(b, body) == 1) { "only PCM WAV files are supported" }
                    channels = le16(b, body + 2)
                    sampleRate = le32(b, body + 4)
                    bits = le16(b, body + 14)
                } else if (id == "data") {
                    require(sampleRate > 0 && bits == 16 && (channels == 1 || channels == 2)) { "only 16-bit mono or stereo PCM" }
                    val length = minOf(len, b.size - body) and 1.inv()   // whole 16-bit samples
                    require(length > 0) { "empty WAV file" }
                    return Wav(b, body, length, sampleRate, channels)
                }
                if (len < 0) break
                pos = body + len + (len and 1)
            }
            throw IllegalArgumentException("WAV file has no data chunk")
        }
    }
}
