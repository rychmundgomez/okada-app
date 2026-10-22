import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config.dart';
import 'features/auth/auth_screen.dart';
import 'features/home/app_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  assert(Config.supabaseUrl.isNotEmpty && Config.supabaseAnonKey.isNotEmpty,
      'Run with --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...');
  await Supabase.initialize(
    url: Config.supabaseUrl,
    anonKey: Config.supabaseAnonKey,
  );
  runApp(const OkadaApp());
}

class OkadaApp extends StatelessWidget {
  const OkadaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OKADA',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFFF59E0B),
      ),
      home: StreamBuilder<AuthState>(
        stream: supabase.auth.onAuthStateChange,
        builder: (context, _) {
          final signedIn = supabase.auth.currentSession != null;
          return signedIn ? const AppGate() : const AuthScreen();
        },
      ),
    );
  }
}
