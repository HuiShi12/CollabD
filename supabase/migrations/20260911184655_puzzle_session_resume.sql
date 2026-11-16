-- UC-05 — save/resume for the Mystery Place Puzzle Game.
-- Adds what ProgressRepository.getActiveSessions/saveProgressSnapshot/
-- touchSession need to resume a tourist mid-puzzle or mid-navigation.
--
-- Also fixes a gap flagged in 20260908151054_game_persistence.sql's own
-- comments: game_sessions identified every player with a placeholder
-- ('tourist_001') under a blanket "any authenticated user, any row" policy.
-- user_id + a real auth.uid()-scoped policy replaces that, matching the
-- pattern trip_path_quests already uses.
--
-- Pre-existing game_sessions rows have user_id = null and become
-- inaccessible under the tightened policy below — acceptable, dev-stage data.

alter table public.game_sessions
  add column if not exists user_id uuid references auth.users(id),
  add column if not exists latitude double precision,
  add column if not exists longitude double precision,
  add column if not exists stage text default 'puzzle',
  add column if not exists puzzle_pieces jsonb,
  add column if not exists hints_left int default 3,
  add column if not exists elapsed_seconds int default 0;

drop policy if exists "game_sessions_authenticated_all" on public.game_sessions;
create policy "game_sessions_owner_all" on public.game_sessions
  for all to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
