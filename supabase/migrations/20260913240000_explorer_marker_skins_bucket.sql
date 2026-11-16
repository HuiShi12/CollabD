-- UC-06 A3 — storage for Explorer Marker Skin master images, generated via
-- Gemini by GeminiApiExternal.generateExplorerMarkerSkinImage and cached in
-- explorer_marker_skin_images (one per design, never regenerated).
-- Same "any authenticated user" insert stance as theme-souvenir-images:
-- whichever tourist's client happens to be the first to reach a given
-- design's milestone is the one that triggers its generation.

insert into storage.buckets (id, name, public)
values ('explorer-marker-skins', 'explorer-marker-skins', true)
on conflict (id) do update set public = true;

drop policy if exists "explorer_marker_skins_bucket_public_read" on storage.objects;
create policy "explorer_marker_skins_bucket_public_read" on storage.objects
  for select using (bucket_id = 'explorer-marker-skins');

drop policy if exists "explorer_marker_skins_bucket_insert_authenticated" on storage.objects;
create policy "explorer_marker_skins_bucket_insert_authenticated" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'explorer-marker-skins');
