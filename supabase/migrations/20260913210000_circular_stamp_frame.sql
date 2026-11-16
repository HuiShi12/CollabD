-- Replaces the rectangular placeholder frame with a circular postmark-style
-- design (double ring + star accent, transparent circular photo window),
-- per the user's requested "circle design stamp, middle empty for image".
-- ImageService.composeDigitalTravelStamp's photo/text layout was updated
-- to match this frame's circular window and band positions.

update public.stamp_frames
set image_url = 'https://umlcjnlubupncwbdntkt.supabase.co/storage/v1/object/public/stamp-frame-assets/placeholder_default_circle.png'
where image_url = 'https://umlcjnlubupncwbdntkt.supabase.co/storage/v1/object/public/stamp-frame-assets/placeholder_default_v2.png';
