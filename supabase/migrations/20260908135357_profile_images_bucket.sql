-- UC-07 A2 — public storage bucket for profile pictures.
-- Used by SupabaseAuthExternal.uploadProfileImage / removeProfileImage.
-- Files are stored at:  profile-images/<auth.uid>/avatar_<timestamp>.<ext>

insert into storage.buckets (id, name, public)
values ('profile-images', 'profile-images', true)
on conflict (id) do update set public = true;

-- anyone can read (bucket is public / avatars shown to the tourist)
drop policy if exists "profile_images_public_read" on storage.objects;
create policy "profile_images_public_read" on storage.objects
  for select using (bucket_id = 'profile-images');

-- a tourist may only write inside their own <user_id>/ folder
drop policy if exists "profile_images_insert_own" on storage.objects;
create policy "profile_images_insert_own" on storage.objects
  for insert with check (
    bucket_id = 'profile-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "profile_images_update_own" on storage.objects;
create policy "profile_images_update_own" on storage.objects
  for update using (
    bucket_id = 'profile-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "profile_images_delete_own" on storage.objects;
create policy "profile_images_delete_own" on storage.objects
  for delete using (
    bucket_id = 'profile-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
