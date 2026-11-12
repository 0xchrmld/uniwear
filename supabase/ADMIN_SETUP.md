# First UniWear administrator

Admin promotion is deliberately manual and must be performed by the Supabase project owner from the SQL Editor. Do not add this operation to the Flutter app.

1. Create the first administrator as a normal student account using the app.
2. Confirm the signup email (if email confirmation is enabled).
3. In Supabase SQL Editor, run this statement, replacing the email with that account's exact email:

```sql
update public.profiles
set role = 'admin'
where id = (
  select id
  from auth.users
  where email = 'first.admin@neu.edu.ph'
);
```

Confirm exactly one row was updated. If zero rows were updated, verify the email and that signup/profile creation completed.

The app reads `profiles.role` after sign-in. The database `is_admin()` helper and RLS/RPC checks enforce access; hiding the Admin page is only a UI convenience.
