import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'audio/audio_out.dart';
import 'audio/sound_bank.dart';
import 'config.dart';
import 'conversation/script.dart';
import 'screens/face_screen.dart';
import 'screens/login_screen.dart';
import 'services/event_log.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // horizontal screen, no system bars
  await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  // Same production project and accounts as the FluffyPaw app; the session (JWT) is kept on the
  // device and refreshed automatically.
  await Supabase.initialize(url: AppConfig.supabaseUrl, anonKey: AppConfig.supabasePublishableKey);
  runApp(const HealthGuardiansApp());
}

class HealthGuardiansApp extends StatelessWidget {
  const HealthGuardiansApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HealthGuardians',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF1E8CFF),
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const _Root(),
    );
  }
}

class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  final SupabaseClient _client = Supabase.instance.client;
  late final StreamSubscription<AuthState> _authSub;
  final AudioOut _audio = NativeAudioOut();
  Session? _session;
  SoundBank? _sounds;
  bool _offline = false;
  final LocalEventLog _localLog = LocalEventLog();
  SupabaseEventLog? _log;
  String? _logUser;

  @override
  void initState() {
    super.initState();
    _session = _client.auth.currentSession;
    _authSub = _client.auth.onAuthStateChange.listen((state) {
      if (mounted) setState(() => _session = state.session);
    });
    // synthesise all sounds once, off the UI thread
    compute(SoundBank.build, phrasesOf(checkInScript)).then((bank) {
      if (mounted) setState(() => _sounds = bank);
    });
  }

  @override
  void dispose() {
    _authSub.cancel();
    super.dispose();
  }

  SupabaseEventLog _eventsFor(String userId) {
    if (_log == null || _logUser != userId) {
      _log = SupabaseEventLog(_client);
      _logUser = userId;
    }
    return _log!;
  }

  @override
  Widget build(BuildContext context) {
    final sounds = _sounds;
    if (sounds == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    final session = _session;
    if (session != null) {
      return FaceScreen(
        key: ValueKey('user-${session.user.id}'),
        sounds: sounds,
        audio: _audio,
        events: _eventsFor(session.user.id),
        accountLabel: session.user.email ?? 'your account',
        onSignOut: () => _client.auth.signOut(),
      );
    }
    if (_offline) {
      return FaceScreen(
        key: const ValueKey('offline'),
        sounds: sounds,
        audio: _audio,
        events: _localLog,
        onSignOut: () => setState(() => _offline = false),
      );
    }
    return LoginScreen(onContinueOffline: () => setState(() => _offline = true));
  }
}
