# UniWear — complete Flutter + Supabase project

This archive contains the Flutter application, Supabase migrations, rollback-only database security tests, admin setup instructions, catalog/photo audit, product assets, and branding assets.

## Start here

1. Install Flutter 3.9+ and Dart 3.9+.
2. From this directory, run `flutter create --platforms=android,ios,web .` (generated native scaffolding is not bundled).
3. Run `flutter pub get`.
4. Obtain the Supabase project URL and publishable key from the Supabase Dashboard.
5. Run the app with `--dart-define=SUPABASE_URL=...` and `--dart-define=SUPABASE_PUBLISHABLE_KEY=...` (see `README.md`).
6. Create a normal student account. Have the project owner promote the first admin manually using `supabase/ADMIN_SETUP.md`.

## Verify

Run `python3 tool/audit_catalog.py`, `flutter analyze`, and `flutter test`. Run `supabase/tests/uniwear_security_tests.sql` in the Supabase SQL Editor as postgres. The SQL tests roll back their test users and orders.

## Important

This is a live Supabase-backed ordering workflow, not an offline demo. No service-role key belongs in the Flutter app. The UI does not process online payments or track stock. Catalog prices originate from the supplied photographed price audit and still require supplier confirmation before real-world sales. Product-image caveats are documented in `PRICING_AND_PHOTOS_AUDIT.md`.
