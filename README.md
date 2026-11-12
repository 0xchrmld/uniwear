# UniWear — New Era University uniform ordering

UniWear is a Flutter application for **Android, iOS, and Web**. The existing interface and bundled product photography are retained; authentication, catalog/pricing, student order history, and admin order management are backed by Supabase.

## Backend status

- Supabase project: `nlwhafwxdxkzttgaztby` (Asia-Pacific Mumbai region)
- Supabase Flutter SDK: `supabase_flutter: 2.18.3` (stable, pinned)
- Client initialization uses `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` build-time defines.
- No service-role key is present in the Flutter source or required by the app.
- Catalog is fetched after authentication and cached in memory. Images remain bundled in `assets/products/` and are selected by each product's `image` field.
- Cart contents remain local in SharedPreferences. The server independently resolves current prices when an order is placed.
- Orders are written only through `place_order`; students can cancel only Pending orders. Admin changes are enforced by `admin_set_status` and RLS/RPC authorization.
- No online payments, inventory, push notifications, realtime, or extra roles are included.

## Connect and run

Install Flutter 3.9+ / Dart 3.9+ and ensure Android, iOS, or Chrome tooling is available. This archive intentionally omits generated native platform scaffolding; create it once from the project root:

```sh
flutter create --platforms=android,ios,web .
flutter pub get
```

Get the **Project URL** and **publishable key** from the Supabase Dashboard → Project Settings → API Keys. Supply them at build/run time; do not paste them into Dart source or commit them:

```sh
flutter run -d chrome \
  --dart-define=SUPABASE_URL=https://nlwhafwxdxkzttgaztby.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_SB_PUBLISHABLE_KEY

flutter run -d android \
  --dart-define=SUPABASE_URL=https://nlwhafwxdxkzttgaztby.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_SB_PUBLISHABLE_KEY

flutter run -d ios \
  --dart-define=SUPABASE_URL=https://nlwhafwxdxkzttgaztby.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_SB_PUBLISHABLE_KEY
```

For release builds use the same defines with `flutter build web`, `flutter build appbundle`, or `flutter build ipa`. The publishable key is designed for public clients; RLS and database privileges are the security boundary.

If the defines are omitted, the app intentionally displays a setup-required screen instead of opening a fake/offline catalog.

## Deploy to GitHub Pages

See [`GITHUB_DEPLOYMENT.md`](GITHUB_DEPLOYMENT.md). The included GitHub Actions workflow builds Flutter Web and deploys on every push to `main`. Add the Supabase Project URL as the `SUPABASE_URL` repository variable and the publishable key as the `SUPABASE_PUBLISHABLE_KEY` repository secret. The workflow creates the missing Flutter Web scaffold on the runner and sets the GitHub Pages repository base path automatically. Never expose a Supabase service-role or secret key in the web build.

## Supabase setup

The SQL migrations are in `supabase/migrations/` and match the migrations already applied to the connected project. The database contains five RLS-enabled public tables: `profiles`, `products`, `product_prices`, `orders`, and `order_items`.

For a fresh project, apply migrations in timestamp order using the Supabase CLI or SQL editor. The database schema is designed for Postgres 17 and the Data API must expose the `public` schema. The `private` schema contains privileged implementation functions and must **not** be added to the Data API exposed schemas.

Configure Supabase Auth:

1. Enable Email as an Auth provider.
2. Configure the email-confirmation policy appropriate for the school deployment.
3. Set the Auth Site URL and allowed redirect URLs for the deployed Web origin and any mobile deep-link callback you configure.
4. Configure SMTP for reliable school email delivery before production use. The app's Forgot Password action calls Supabase `resetPasswordForEmail`.

New accounts require full name, student number, email, and password. The database creates each profile from signup metadata with the `student` role. Signup metadata cannot promote an account.

## First administrator (manual owner-only step)

Create the first account normally, confirm its email if required, then have the **Supabase project owner** run the SQL in [`supabase/ADMIN_SETUP.md`](supabase/ADMIN_SETUP.md). Admin promotion is deliberately not available in the app.

## Database security

- RLS is enabled on every public application table.
- Students can select only their own orders and order items.
- Authenticated users can read active catalog products and prices.
- Product/price writes are restricted to admins.
- Clients have no direct INSERT/UPDATE/DELETE privileges on orders or order items.
- Profile updates are column-granted for `full_name` and `student_number`; `role` is not updatable by an authenticated client.
- Public RPC wrappers are invoker functions; privileged implementations live in non-exposed `private` schema functions, check `auth.uid()`, and set an empty `search_path`.
- Prices and product names are snapshotted on order items. The server ignores any price supplied by the client.

See `supabase/tests/uniwear_security_tests.sql` for rollback-only SQL tests and `tool/audit_catalog.py` for a pricing audit check.

## Catalog and source-photo caveats

The app has 12 active catalog entries. The two P.E. items remain view-only because no reliable price was visible. College Blouse and Polo with Patch remain excluded. The 65 priced sizes in the SQL seed match `PRICING_AND_PHOTOS_AUDIT.md`.

The supplied ZIP's `lib/main.dart` is already a Supabase-backed version and contains an empty in-memory `catalog` placeholder; it does **not** contain the original hardcoded catalog constant described in the request. The existing SQL seed therefore reflects the product catalog already included in the deployed migration and has been checked against the supplied pricing audit, rather than falsely claiming it was re-extracted from the absent Dart constant. `tool/audit_catalog.py` validates all 12 product IDs and 65 prices against the audit.

The bundled product images are illustrative/AI-assisted where documented. Check `PRICING_AND_PHOTOS_AUDIT.md`, `CATALOG_IMAGE_AUDIT.jpg`, and `CAMPUS_PHOTO_CREDITS.md` before school-wide publication. The app does not claim official NEU endorsement.

## Verification

```sh
python3 tool/audit_catalog.py
flutter analyze
flutter test
```

Run the SQL test script from the Supabase SQL Editor as the database owner. Flutter analyze/test require a local Flutter SDK; this development environment may not include Flutter/Xcode/Android SDK tooling.
