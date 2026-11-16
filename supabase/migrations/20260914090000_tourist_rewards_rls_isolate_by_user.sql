-- UC-06 Manage Rewards — real per-user isolation.
--
-- The original policy (20260913200000_tourist_rewards_table.sql) was
-- deliberately `using (true)` for every authenticated user, because
-- CurrentTourist.id was a hardcoded demo string ('tourist_001') shared by
-- every signed-in account rather than the real auth.uid() — so scoping by
-- tourist_id would have been meaningless at the time.
--
-- CurrentTourist.id now resolves to the real Supabase Auth user id
-- (lib/Data_layer/repository/User Repository/current_tourist.dart), so this
-- closes the gap: a signed-in user can only see and modify their own reward
-- rows, enforced by Postgres itself rather than only by the app's own
-- .eq('tourist_id', touristId) query filters (which a client could bypass).
--
-- Consequence (accepted, per product decision): existing rows still carrying
-- the old shared tourist_id = 'tourist_001' become unreachable by any real
-- account. That data was never meaningfully tied to one person anyway, so
-- it is intentionally left in place rather than migrated or deleted.

drop policy if exists "tourist_rewards_authenticated_all" on public.tourist_rewards;

create policy "tourist_rewards_select_own" on public.tourist_rewards
  for select to authenticated
  using (tourist_id = auth.uid()::text);

create policy "tourist_rewards_insert_own" on public.tourist_rewards
  for insert to authenticated
  with check (tourist_id = auth.uid()::text);

create policy "tourist_rewards_update_own" on public.tourist_rewards
  for update to authenticated
  using (tourist_id = auth.uid()::text)
  with check (tourist_id = auth.uid()::text);

create policy "tourist_rewards_delete_own" on public.tourist_rewards
  for delete to authenticated
  using (tourist_id = auth.uid()::text);
