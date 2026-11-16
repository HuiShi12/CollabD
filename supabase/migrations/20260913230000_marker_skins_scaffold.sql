-- UC-06 A3/A3-1 — Explorer Marker Skins scaffolding.
--
-- is_equipped: added to tourist_rewards (not a new table) since a skin
-- reward is still a TouristReward — just one with an extra piece of state
-- (whether it's the tourist's currently-equipped map marker). At most one
-- row per tourist should have this true; RewardRepository enforces that
-- when equipping, not a DB constraint (mirrors how one-per-theme
-- Duplicate-prevention is enforced in code, not SQL, elsewhere here).
alter table public.tourist_rewards
  add column if not exists is_equipped boolean not null default false;

-- explorer_marker_skin_images: the "generate once, reuse forever" master
-- image cache (UC-06 C4: Unique Marker Skin Master Image). Unlike
-- theme_souvenir_images (a consumed pool) or tourist_rewards (one row per
-- tourist), this has exactly one row per configured skin design — the
-- design list itself is a static Dart config (RewardRepository
-- .markerSkinDesigns), not stored here, since it's developer-configured,
-- not generated/user data. This table only caches the Gemini output so a
-- given design's artwork is never regenerated once it exists.
create table if not exists public.explorer_marker_skin_images (
  design_id text primary key,
  image_url text not null,
  created_at timestamptz not null default now()
);

alter table public.explorer_marker_skin_images enable row level security;

drop policy if exists "explorer_marker_skin_images_authenticated_all" on public.explorer_marker_skin_images;
create policy "explorer_marker_skin_images_authenticated_all" on public.explorer_marker_skin_images
  for all to authenticated
  using (true)
  with check (true);
