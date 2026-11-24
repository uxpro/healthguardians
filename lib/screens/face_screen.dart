import 'package:flutter/material.dart';

import '../audio/audio_out.dart';
import '../audio/sound_bank.dart';
import '../conversation/conversation.dart';
import '../face/face_mode.dart';
import '../face/face_view.dart';
import '../services/event_log.dart';

/// Full-screen face on black. Tap the face to start a check-in.
class FaceScreen extends StatefulWidget {
  const FaceScreen({
    super.key,
    required this.sounds,
    required this.audio,
    required this.events,
    this.accountLabel,
    this.onSignOut,
  });

  final SoundBank sounds;
  final AudioOut audio;
  final EventSink events;

  /// E-mail of the signed-in account, or null without an account.
  final String? accountLabel;
  final VoidCallback? onSignOut;

  @override
  State<FaceScreen> createState() => _FaceScreenState();
}

class _FaceScreenState extends State<FaceScreen> {
  late final Conversation _talk;

  @override
  void initState() {
    super.initState();
    _talk = Conversation(sounds: widget.sounds, audio: widget.audio, events: widget.events);
    _talk.enterIdle();
  }

  @override
  void dispose() {
    _talk.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (!_talk.running) _talk.start();
              },
              child: FaceView(mode: () => _talk.mode, envelope: _talk.envelopeNow),
            ),
          ),
          Positioned.fill(
            child: SafeArea(
              child: ListenableBuilder(
                listenable: _talk,
                builder: (context, _) => _Overlay(
                  talk: _talk,
                  events: widget.events,
                  accountLabel: widget.accountLabel,
                  onSignOut: widget.onSignOut,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Overlay extends StatelessWidget {
  const _Overlay({required this.talk, required this.events, this.accountLabel, this.onSignOut});

  final Conversation talk;
  final EventSink events;
  final String? accountLabel;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    final palette = FacePalette.of(talk.mode);
    final asking = talk.asking;
    final acting = talk.acting;
    final caption = talk.caption ?? (talk.running ? null : 'Tap the face to start the check-in');
    return Stack(
      children: [
        // status and controls, kept faint so the face stays in front
        Positioned(
          top: 8,
          left: 12,
          child: ValueListenableBuilder<EventLogStatus>(
            valueListenable: events.status,
            builder: (context, status, _) => _StatusChip(status: status, account: accountLabel),
          ),
        ),
        Positioned(
          top: 0,
          right: 4,
          child: Row(children: [
            if (talk.running)
              IconButton(
                tooltip: 'Stop the check-in',
                icon: const Icon(Icons.stop_circle_outlined, color: Colors.white38),
                onPressed: talk.cancel,
              ),
            if (onSignOut != null)
              IconButton(
                tooltip: accountLabel == null ? 'Sign in' : 'Sign out',
                icon: Icon(accountLabel == null ? Icons.login : Icons.logout, color: Colors.white38),
                onPressed: onSignOut,
              ),
          ]),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 16,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (caption != null)
                Text(
                  caption,
                  key: const Key('caption'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white.withAlpha(170), fontSize: 20, letterSpacing: 0.3),
                ),
              if (acting != null) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: 280,
                  child: LinearProgressIndicator(
                    value: 1 - talk.actionRemaining.inMilliseconds / acting.duration.inMilliseconds,
                    color: palette.core,
                    backgroundColor: Colors.white12,
                    minHeight: 3,
                  ),
                ),
                const SizedBox(height: 6),
                Text('${talk.actionRemaining.inSeconds} s',
                    key: const Key('countdown'), style: const TextStyle(color: Colors.white54, fontSize: 14)),
              ],
              if (asking != null) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  children: [
                    for (final option in asking.options)
                      OutlinedButton(
                        key: Key('answer-${option.value}'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(color: palette.aura.withAlpha(180)),
                          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                          textStyle: const TextStyle(fontSize: 18),
                        ),
                        onPressed: () => talk.answer(option),
                        child: Text(option.label),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status, this.account});

  final EventLogStatus status;
  final String? account;

  @override
  Widget build(BuildContext context) {
    final (color, text) = switch (status) {
      EventLogStatus.ready => (const Color(0xFF4CAF50), 'Events saved to ${account ?? 'your account'}'),
      EventLogStatus.failed => (const Color(0xFFE57373), 'Events not saved yet (retrying)'),
      EventLogStatus.offline => (Colors.white38, 'Not signed in: events are not saved'),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Text(text, key: const Key('event-status'), style: const TextStyle(color: Colors.white38, fontSize: 12)),
      ],
    );
  }
}
