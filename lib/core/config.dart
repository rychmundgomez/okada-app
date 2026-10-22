import 'package:supabase_flutter/supabase_flutter.dart';

/// Values are passed at build time, never hard-coded:
/// flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
class Config {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
}

SupabaseClient get supabase => Supabase.instance.client;

/// Turns 024xxxxxxx / 24xxxxxxx / +23324xxxxxxx into +23324xxxxxxx.
String normalizeGhPhone(String input) {
  var p = input.replaceAll(RegExp(r'[\s\-()]'), '');
  if (p.startsWith('+233')) return p;
  if (p.startsWith('233')) return '+$p';
  if (p.startsWith('0')) return '+233${p.substring(1)}';
  return '+233$p';
}
