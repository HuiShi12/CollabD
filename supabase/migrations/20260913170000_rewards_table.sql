-- UC-06 Manage Rewards — real persistence for TouristReward records.
-- Previously insertReward/getRewardsForTourist/findReward/updateRewardStatus
-- (s.dart) wrote to an in-memory `_rewards` map, which is why every earned
-- Digital Travel Stamp / Theme Souvenir disappeared on the next app run —
-- it was never actually saved anywhere.
--
-- RLS note: CurrentTourist.id is still a hardcoded demo value shared by
-- every signed-in user (see current_tourist.dart's own TODO), not yet the
-- real auth.uid(). Scoping this table's policy by tourist_id would give no
-- real security today since all users share that id, so this matches the
-- same "any authenticated user, any row" stance game_sessions originally
-- used (20260908151054) before its own auth.uid() tightening. Tighten this
-- the same way once CurrentTourist.id is replaced with the real signed-in
-- user id.

create table if not exists public.rewards (
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

alter table public.rewards enable row level security;

drop policy if exists "rewards_authenticated_all" on public.rewards;
create policy "rewards_authenticated_all" on public.rewards
  for all to authenticated
  using (true)
  with check (true);
