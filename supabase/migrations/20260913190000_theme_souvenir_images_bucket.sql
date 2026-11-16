-- UC-06 — storage for real Gemini-generated Theme Souvenir Images.
-- Used by GeminiApiExternal.generateThemeSouvenirImageUrl. Unlike
-- verified-photos/digital-travel-stamps, this catalogue is shared across
-- every tourist (not scoped to one uploader's folder) — matching
-- theme_souvenir_images' own "any authenticated user" RLS stance
-- (20260913180000), since any signed-in tourist's client may be the one
-- that happens to trigger catalogue replenishment.

insert into storage.buckets (id, name, public)
values ('theme-souvenir-images', 'theme-souvenir-images', true)
on conflict (id) do update set public = true;

drop policy if exists "theme_souvenir_images_bucket_public_read" on storage.objects;
create policy "theme_souvenir_images_bucket_public_read" on storage.objects
  for select using (bucket_id = 'theme-souvenir-images');

drop policy if exists "theme_souvenir_images_bucket_insert_authenticated" on storage.objects;
create policy "theme_souvenir_images_bucket_insert_authenticated" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'theme-souvenir-images');
