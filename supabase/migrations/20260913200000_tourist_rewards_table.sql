-- UC-06 Manage Rewards — real persistence for TouristReward records.
--
-- Supersedes 20260913170000_rewards_table.sql, which targeted a table
-- named `rewards` — but that name was already taken by a different,
-- pre-existing table belonging to Profile Management's "Rewards Earned"
-- statistic (sa.dart: rewards.user_id / rewards.is_unlocked, an unrelated
-- schema). `create table if not exists` against that name silently did
-- nothing, so Manage Rewards kept trying to read/write columns
-- (tourist_id, source_id, ...) that don't exist on that other table —
-- hence the "column rewards.tourist_id does not exist" error.
--
-- This creates a correctly-named, non-colliding table instead. The old
-- `rewards` table is left untouched since Profile Management still uses it.
--
-- RLS note: same stance as the superseded migration — CurrentTourist.id is
-- still a hardcoded demo value shared by every signed-in user, not the
-- real auth.uid(), so this can't be meaningfully scoped by tourist_id yet.

create table if not exists public.tourist_rewards (
  id text primary key,
  tourist_id text not null,
  source_id text not null,
  image_url text not null,
  type text not null,
  status text not null,
  completed_at timestamptz not null,
  earned_at timestamptz,
  hidden_place_id text,
  hidden_place_name text,
  township text,
  verified_photo_url text,
  theme text,
  completed_checkpoints int,
  total_checkpoints int,
  created_at timestamptz not null default now()
);

alter table public.tourist_rewards enable row level security;

drop policy if exists "tourist_rewards_authenticated_all" on public.tourist_rewards;
create policy "tourist_rewards_authenticated_all" on public.tourist_rewards
  for all to authenticated
  using (true)
  with check (true);
