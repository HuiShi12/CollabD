-- Removes dead schema left over from an abandoned early Puzzle prototype
-- and an unused planned reward-request flow, plus a handful of columns
-- that have sat permanently empty since Trip Path Quest repurposed their
-- tables for a simpler design than originally planned.
--
-- Every table/column dropped here was confirmed, via a full search of
-- lib/**/*.dart for `.from('table_name')` calls (this codebase's only way
-- of touching a Supabase table), to have zero references in the current
-- app before this migration was written:
--
-- - puzzle_games / puzzle_progress — ongyeukang's original Puzzle Game
--   prototype (see 20260908151054_game_persistence.sql's own comment,
--   which already called these "left untouched"). Superseded by
--   game_sessions once the real Mystery Place Puzzle Game landed. Both
--   tables were empty (0 rows) — nothing to preserve.
-- - password_security — no CREATE TABLE for this table exists anywhere in
--   this repo's migration history; it predates migration tracking, and
--   nothing in the app reads or writes it. Had 3 leftover rows, exported
--   to a local JSON backup before this migration ran.
-- - reward_requests — created in 20260908151054_game_persistence.sql for a
--   planned `RewardRepository.createRewardRequest` flow (UC-05 step 24)
--   that was never built; the real reward pipeline uses `tourist_rewards`
--   instead (see 20260913200000_tourist_rewards_table.sql). Had 5
--   leftover rows, exported to a local JSON backup before this migration
--   ran.
--
-- landmarks.township / landmarks.description / landmarks.image_url —
-- columns from ongyeukang's original landmarks design. Trip Path Quest's
-- user_landmark_visit_repository.dart re-uses this table but only ever
-- writes google_place_id / name / address / primary_type / latitude /
-- longitude / photo_resource_name — these three were 0/151 populated and
-- untouched by any current code path.
--
-- user_landmark_visits.verification_status / proof_image_url / confidence
-- — never set by markVisited() (only user_id / landmark_id / visited_at
-- are written); the real per-checkpoint photo-verification outcome lives
-- in trip_path_quest_checkpoints instead. Every row sat at its column
-- default ('pending' / null) forever.

-- FK order matters: puzzle_progress references puzzle_games, so it must
-- go first.
drop table if exists public.puzzle_progress;
drop table if exists public.puzzle_games;
drop table if exists public.password_security;
drop table if exists public.reward_requests;

alter table public.landmarks
  drop column if exists township,
  drop column if exists description,
  drop column if exists image_url;

alter table public.user_landmark_visits
  drop column if exists verification_status,
  drop column if exists proof_image_url,
  drop column if exists confidence;
