-- Restores public.password_security, wrongly dropped by
-- 20260914110000_cleanup_dead_tables_and_columns.sql.
--
-- That earlier migration confirmed "dead" schema by grepping lib/**/*.dart
-- for `.from('table_name')` calls — but this table is only ever touched
-- from Supabase Edge Functions (supabase/functions/*/index.ts), which live
-- outside the Flutter client and outside that search entirely:
--
-- - supabase/functions/secure-password-update/index.ts — reads the stored
--   fingerprint to reject a "new" password that hashes the same as the
--   current one (case/whitespace-insensitive similarity check), then
--   upserts the new fingerprint after a successful password change. Powers
--   both UC-07's "Change Password" and the forgot-password reset flow.
-- - supabase/functions/initialize-password-fingerprint/index.ts — seeds the
--   first fingerprint right after signup.
--
-- With the table gone, both functions' queries against it errored
-- (`relation "password_security" does not exist`), which is what actually
-- caused "Reset Password" (and presumably new signups' fingerprint
-- initialization) to fail with a generic "Unable to update password" /
-- "Unable to initialize password security" — not a client-side bug.
--
-- Schema reconstructed from: the edge functions' own query shapes
-- (`.eq('user_id', ...).maybeSingle()` and `.upsert(..., {onConflict:
-- 'user_id'})` both require `user_id` to carry a unique constraint), and
-- the 3 rows exported to a local JSON backup before the drop (restored
-- below) — columns were exactly user_id / password_fingerprint /
-- created_at / updated_at, matching this definition.

create table if not exists public.password_security (
  user_id uuid primary key references auth.users(id) on delete cascade,
  password_fingerprint text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Deliberately no policies: every access to this table goes through Edge
-- Functions using the service-role client (`ctx.supabaseAdmin`), which
-- bypasses RLS regardless. Enabling RLS with zero policies means a direct
-- anon/authenticated client query (there should never be one) reads/writes
-- nothing instead of falling back to default-open.
alter table public.password_security enable row level security;

-- Restore the 3 rows that existed before the earlier migration dropped the
-- table (exported to local JSON first). Re-inserting them preserves each
-- affected user's real similarity check instead of silently resetting it
-- for a comparison against their next password change only.
insert into public.password_security (user_id, password_fingerprint, created_at, updated_at)
values
  ('135e3c85-39d9-47a1-b701-a080b2cfa0b0', '9b3ea022ebe0d365f3e91c34ee55c5cf056614d5ce390556e47d4b7bb67decc4', '2026-09-09 16:54:51.052113+00', '2026-09-10 06:30:58.669+00'),
  ('3896624c-b07b-43cb-b51a-4aaf317b5816', 'efa49cd5f213edac9c5b862eec9ff705d9f343fa59038d04415080b6b5558b9f', '2026-09-10 09:39:32.08212+00', '2026-09-10 09:39:32.08212+00'),
  ('9c7b391b-6b5f-4041-8d08-6660be2574d0', '9b3ea022ebe0d365f3e91c34ee55c5cf056614d5ce390556e47d4b7bb67decc4', '2026-09-11 18:21:43.110082+00', '2026-09-11 18:21:43.110082+00')
on conflict (user_id) do nothing;
