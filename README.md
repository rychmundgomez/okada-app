# okada-app
A proposed motorcycle ride-hailing platform for the Volta Region, Ghana.

Stack: Flutter (Android first) + Supabase (Postgres/PostGIS, phone auth, realtime, storage).

## Setup
1. Generate the Android project files (keeps existing `lib/`):
   `flutter create --org com.okada --platforms android --project-name okada_app .`
   then `git checkout lib pubspec.yaml` if Flutter changed them.
2. `flutter pub get`
3. In Supabase, run `supabase/migrations/20261021200000_init_schema.sql` in the SQL editor.
4. Supabase > Authentication > Providers > Phone: connect an SMS provider (or add a test number).
5. Run:
   `flutter run --dart-define=SUPABASE_URL=<url> --dart-define=SUPABASE_ANON_KEY=<anon key>`

First admin: `update public.profiles set role = 'admin' where phone = '233XXXXXXXXX';`
