-- theme_artworks previously only had a SELECT policy (authenticated, active
-- rows only). Generated Theme Souvenir images now register themselves into
-- this shared pool (see GeminiApiExternal.generateThemeSouvenirImageUrl) so
-- every tourist benefits from a generation instead of just the one request
-- that triggered it -- that requires an INSERT policy, which did not exist
-- yet. Scoped to INSERT only (not UPDATE/DELETE) so the curated rows stay
-- protected from client-side tampering; only adding new rows is allowed.
create policy "theme_artworks_authenticated_insert"
  on public.theme_artworks
  for insert
  to authenticated
  with check (true);
