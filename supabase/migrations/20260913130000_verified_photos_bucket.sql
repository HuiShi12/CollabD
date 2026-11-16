-- UC-05 / UC-06 — public storage bucket for verified visit photos.
-- Used by ImageService.uploadCapturedPhoto so a Digital Travel Stamp's
-- imageUrl/verifiedPhotoUrl is a real Supabase Storage URL instead of a
-- local device file path (which RewardImage cannot render, and which
-- would not survive past the device that took the photo anyway).
--
-- A base64/data-URI approach was intentionally avoided here — it would
-- bloat every reward record and the device's memory with the full image
-- bytes. Storing a URL and letting Supabase Storage serve the bytes keeps
-- reward records small, mirroring profile-images (20260908135357).
--
-- Files are stored at: verified-photos/<auth.uid>/visit_<timestamp>.<ext>

insert into storage.buckets (id, name, public)
values ('verified-photos', 'verified-photos', true)
on conflict (id) do update set public = true;

drop policy if exists "verified_photos_public_read" on storage.objects;
create policy "verified_photos_public_read" on storage.objects
  for select using (bucket_id = 'verified-photos');

drop policy if exists "verified_photos_insert_own" on storage.objects;
create policy "verified_photos_insert_own" on storage.objects
  for insert with check (
    bucket_id = 'verified-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
