-- UC-05 / UC-06 — real persistence for the exploration-game side.
-- Written by External_services/Supabase/s.dart (SupabaseExternal).
--
-- NOTE: the puzzle module currently identifies the player with a placeholder
-- (`tourist_id = 'tourist_001'`), not the real auth uid, so RLS here only
-- requires an authenticated session. Tighten to `auth.uid()` once the puzzle
-- flow is wired to real auth.
--
-- ongyeukang's earlier tables `puzzle_games` / `landmarks` / `puzzle_progress`
-- / `rewards` are left untouched — his `getPuzzleByLandmark` path is not yet
-- wired into the game flow.

-- ---------------------------------------------------------------------------
-- game_sessions  — ProgressRepository.createGameSession / savePuzzleCompleted /
--                  saveVisitVerifiedAndCompleteGame / getGameSession
-- ---------------------------------------------------------------------------
create table if not exists public.game_sessions (
  id uuid primary key default gen_random_uuid(),
  tourist_id text,
  mission_id text,
  hidden_place_id text,
  hidden_place_name text,
  township text,
  category text,
  reference_image_url text,
  status text,
  puzzle_completed boolean default false,
  visit_verified boolean default false,
  puzzle_completed_at timestamptz,
  verified_tourist_photo_url text,
  verification_message text,
  completion_date timestamptz,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

alter table public.game_sessions enable row level security;
drop policy if exists "game_sessions_authenticated_all" on public.game_sessions;
create policy "game_sessions_authenticated_all" on public.game_sessions
  for all to authenticated using (true) with check (true);

-- ---------------------------------------------------------------------------
-- visit_proofs  — VisitProofRepository.verifyVisit
-- ---------------------------------------------------------------------------
create table if not exists public.visit_proofs (
  id uuid primary key default gen_random_uuid(),
  hidden_place_id text,
  hidden_place_name text,
  township text,
  reference_image_url text,
  submitted_photo_path text,
  verification_status text,
  message text,
  verified_at timestamptz,
  created_at timestamptz default now()
);

alter table public.visit_proofs enable row level security;
drop policy if exists "visit_proofs_authenticated_all" on public.visit_proofs;
create policy "visit_proofs_authenticated_all" on public.visit_proofs
  for all to authenticated using (true) with check (true);

-- ---------------------------------------------------------------------------
-- reward_requests  — RewardRepository.createRewardRequest (UC-05 step 24 →
--                    UC-06 Manage Rewards). Distinct from ongyeukang's
--                    `rewards` catalogue table.
-- ---------------------------------------------------------------------------
create table if not exists public.reward_requests (
  id uuid primary key default gen_random_uuid(),
  tourist_id text,
  hidden_place_id text,
  hidden_place_name text,
  township text,
  verified_tourist_photo_url text,
  completion_date timestamptz,
  reward_type text,
  reward_status text,
  request_source text,
  created_at timestamptz default now()
);

alter table public.reward_requests enable row level security;
drop policy if exists "reward_requests_authenticated_all" on public.reward_requests;
create policy "reward_requests_authenticated_all" on public.reward_requests
  for all to authenticated using (true) with check (true);
