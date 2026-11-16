-- Fixes account deletion failing with "Database error deleting user".
--
-- 20260911184655_puzzle_session_resume.sql added game_sessions.user_id
-- referencing auth.users(id) WITHOUT on delete cascade (unlike profiles.id
-- and trip_path_quests.user_id in the same batch, which both got it
-- correctly). Postgres's default NO ACTION then blocks
-- auth.admin.deleteUser() whenever the tourist still has any game_sessions
-- row — exactly the delete-account Edge Function failure being fixed here.

alter table public.game_sessions
  drop constraint if exists game_sessions_user_id_fkey;

alter table public.game_sessions
  add constraint game_sessions_user_id_fkey
  foreign key (user_id) references auth.users (id) on delete cascade;
