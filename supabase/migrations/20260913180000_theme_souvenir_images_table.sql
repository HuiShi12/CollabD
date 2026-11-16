-- UC-06 Manage Rewards — real persistence for the Theme Souvenir Image
-- catalogue (theme, image_url, is_available, assigned_quest_id, ...).
-- Previously an in-memory `_themeSouvenirImages` map in s.dart — the same
-- bug class as the old `_rewards` map (20260913170000): it reset to empty
-- on every app run, so every restart looked like "no images available" and
-- forced RewardRepository.checkAndReplenishThemeCatalogue to regenerate
-- the whole catalogue from zero instead of ever actually accumulating one.
--
-- RLS note: same stance as rewards (20260913170000) — this catalogue is
-- shared across all tourists (not scoped by tourist_id at all), so any
-- authenticated user needs full access for the client-side replenishment
-- logic in RewardRepository to work.

create table if not exists public.theme_souvenir_images (
  id uuid primary key default gen_random_uuid(),
  theme text not null,
  image_url text not null,
  is_available boolean not null default true,
  assigned_quest_id text,
  assigned_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.theme_souvenir_images enable row level security;

drop policy if exists "theme_souvenir_images_authenticated_all" on public.theme_souvenir_images;
create policy "theme_souvenir_images_authenticated_all" on public.theme_souvenir_images
  for all to authenticated
  using (true)
  with check (true);
