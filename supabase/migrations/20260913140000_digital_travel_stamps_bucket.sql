-- UC-06 A6 — public storage bucket for composed Digital Travel Stamps.
-- Used by ImageService.composeDigitalTravelStamp: the verified photo is
-- drawn inside the picked stamp_frames design plus place/township/date
-- text, rendered to a PNG in memory, then uploaded here — only the
-- resulting public URL is stored on the reward record (reward.imageUrl),
-- not the image bytes.
--
-- Files are stored at: digital-travel-stamps/<auth.uid>/stamp_<timestamp>.png

insert into storage.buckets (id, name, public)
values ('digital-travel-stamps', 'digital-travel-stamps', true)
on conflict (id) do update set public = true;

drop policy if exists "digital_travel_stamps_public_read" on storage.objects;
create policy "digital_travel_stamps_public_read" on storage.objects
  for select using (bucket_id = 'digital-travel-stamps');

drop policy if exists "digital_travel_stamps_insert_own" on storage.objects;
create policy "digital_travel_stamps_insert_own" on storage.objects
  for insert with check (
    bucket_id = 'digital-travel-stamps'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
