-- UC-06 — storage for the hand-seeded Digital Travel Stamp frame designs
-- referenced by public.stamp_frames.image_url (see 20260913120000).
-- Unlike verified-photos/digital-travel-stamps, tourists never write here —
-- only the dev team uploads/replaces frame designs (via the dashboard or
-- `supabase storage cp`), so this bucket only needs a public-read policy.

insert into storage.buckets (id, name, public)
values ('stamp-frame-assets', 'stamp-frame-assets', true)
on conflict (id) do update set public = true;

drop policy if exists "stamp_frame_assets_public_read" on storage.objects;
create policy "stamp_frame_assets_public_read" on storage.objects
  for select using (bucket_id = 'stamp-frame-assets');

-- Point the placeholder stamp_frames row (seeded in 20260913120000) at a
-- real uploaded image instead of the inert 'mock://' string, so
-- ImageService.composeDigitalTravelStamp can actually download and draw it
-- before the real 6 frame designs are ready.
update public.stamp_frames
set image_url = 'https://umlcjnlubupncwbdntkt.supabase.co/storage/v1/object/public/stamp-frame-assets/placeholder_default.png'
where image_url = 'mock://stamp_frames/placeholder_default';
