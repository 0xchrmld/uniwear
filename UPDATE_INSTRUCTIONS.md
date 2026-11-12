# Updating UniWear

1. Back up your existing project folder.
2. Copy the updated `lib/`, `assets/`, `supabase/`, `tool/`, `test/`, and `pubspec.yaml` into the project.
3. If native platform folders are missing, run `flutter create --platforms=android,ios,web .` from the project root.
4. Run `flutter pub get`.
5. Supply `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` with `--dart-define` when running or building.
6. Run `python3 tool/audit_catalog.py`, `flutter analyze`, and `flutter test`.

## Backend behavior

- Supabase Auth uses email/password only.
- The catalog and prices load from Supabase after sign-in.
- Cart data remains local to the device/browser; order data is stored in Supabase.
- Order placement, cancellation, and admin status changes use protected RPCs.
- Admin access is granted manually by the Supabase project owner; see `supabase/ADMIN_SETUP.md`.

No offline fake orders or demo credentials are provided. If the backend cannot be reached, UniWear shows a visible retry screen instead of silently switching to local order data.
