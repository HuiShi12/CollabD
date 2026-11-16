-- The first placeholder_default.png (20260913150000) was fully opaque —
-- it hid the composited photo entirely instead of framing it, since a
-- frame image needs a transparent centre for ImageService.
-- composeDigitalTravelStamp's photo-then-frame draw order to work.
-- placeholder_default_v2.png replaces it with a real transparent-window
-- frame (title banner + photo window + caption footer).

update public.stamp_frames
set image_url = 'https://umlcjnlubupncwbdntkt.supabase.co/storage/v1/object/public/stamp-frame-assets/placeholder_default_v2.png'
where image_url = 'https://umlcjnlubupncwbdntkt.supabase.co/storage/v1/object/public/stamp-frame-assets/placeholder_default.png';
