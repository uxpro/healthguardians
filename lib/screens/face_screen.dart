import 'package:flutter/material.dart';

import '../audio/audio_out.dart';
import '../audio/sound_bank.dart';
import '../conversation/conversation.dart';
import '../face/face_view.dart';
import '../services/event_log.dart';

/// Full-screen face on black. Nothing is written on screen while the face talks: no captions, no
/// answer buttons. With [autoStart] the conversation starts once, as soon as the screen opens
/// (the demo after "Continue without signing in"); otherwise a tap on the face starts it.
class FaceScreen extends StatefulWidget {
  const FaceScreen({
    super.key,
    required this.sounds,
    required this.audio,
    required this.events,
    this.accountLabel,
    this.onSignOut,
    this.autoStart = false,
  });

  final SoundBank sounds;
  final AudioOut audio;
  final EventSink events;

  /// E-mail of the signed-in account, or null without an account.
  final String? accountLabel;
  final VoidCallback? onSignOut;

  /// Start the conversation once when the screen opens; a tap on the face does not restart it.
  final bool autoStart;

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
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _talk.start();
      });
    }
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
              onTap: widget.autoStart
                  ? null
                  : () {
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
    return Stack(
      children: [
        // signed in: a faint line says whether the events reach the database (nothing for the demo)
        if (accountLabel != null)
          Positioned(
            top: 8,
            left: 12,
            child: ValueListenableBuilder<EventLogStatus>(
              valueListenable: events.status,
              builder: (context, status, _) => _StatusChip(status: status, account: accountLabel),
            ),
          ),
        // faint icons only, so the face stays alone on screen
        Positioned(
          top: 0,
          right: 4,
          child: Row(children: [
            if (talk.running)
              IconButton(
                tooltip: 'Stop',
                icon: const Icon(Icons.stop_circle_outlined, color: Colors.white24),
                onPressed: talk.cancel,
              ),
            if (onSignOut != null)
              IconButton(
                tooltip: accountLabel == null ? 'Sign in' : 'Sign out',
                icon: Icon(accountLabel == null ? Icons.login : Icons.logout, color: Colors.white24),
                onPressed: onSignOut,
              ),
          ]),
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
      EventLogStatus.offline => (Colors.white38, 'Events are not saved'),
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
