-- UC-06 — Digital Travel Stamp frame designs.
-- Unlike the Theme Souvenir Image catalogue, frames are never consumed:
-- the same row is reused across every tourist's stamp, so this is a small,
-- hand-seeded table (rows added/replaced via the dashboard), not something
-- the app generates or replenishes at runtime.
--
-- RewardRepository._randomStampFrameUrl() reads this table and picks one
-- row at random each time a Digital Travel Stamp is generated.

create table if not exists public.stamp_frames (
  id uuid primary key default gen_random_uuid(),
  image_url text not null,
  created_at timestamptz not null default now()
);

alter table public.stamp_frames enable row level security;

drop policy if exists "stamp_frames_authenticated_read" on public.stamp_frames;
create policy "stamp_frames_authenticated_read" on public.stamp_frames
  for select to authenticated
  using (true);

-- Placeholder so the table isn't empty (and Digital Travel Stamp generation
-- doesn't hard-fail) before the real 6 frame designs are ready. Replace/add
-- rows with the real designs via the Supabase dashboard once available.
insert into public.stamp_frames (image_url)
values ('mock://stamp_frames/placeholder_default')
on conflict do nothing;
