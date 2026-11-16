-- UC-01 / UC-02 / UC-07 — profiles table + UC-07 Game & Place History source table.

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  full_name text,
  date_of_birth date,
  avatar_url text,
  updated_at timestamptz default now()
);

-- brought in by the manage_profile merge (avatar picture)
alter table public.profiles add column if not exists avatar_url text;

alter table public.profiles enable row level security;

drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own" on public.profiles
  for select using (auth.uid() = id);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles
  for update using (auth.uid() = id);

drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own" on public.profiles
  for insert with check (auth.uid() = id);

-- ---------------------------------------------------------------------------
-- UC-02 BF-10 — create a profile row automatically after OTP-verified signup.
-- full_name / date_of_birth are carried in auth user metadata by SupabaseAuthExternal.signUp.
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name, date_of_birth)
  values (
    new.id,
    new.email,
    new.raw_user_meta_data ->> 'full_name',
    nullif(new.raw_user_meta_data ->> 'date_of_birth', '')::date
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- trip_path_quests — read by UC-07 A3 "Game & Place History".
-- Written by the UC-05 Trip Path Quest game (not yet integrated), so it stays
-- empty for now; history simply shows nothing until that module lands.
-- ---------------------------------------------------------------------------
create table if not exists public.trip_path_quests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  theme_id text not null,
  theme_name text not null,
  status text not null default 'in_progress',        -- in_progress | completed | abandoned
  current_checkpoint int not null default 1,
  completed_checkpoints int not null default 0,
  total_checkpoints int not null default 3,
  started_at timestamptz not null default now(),
  last_played_at timestamptz not null default now(),
  completed_at timestamptz,
  abandoned_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  artwork_id text
);

create index if not exists trip_path_quests_user_id_idx
  on public.trip_path_quests (user_id, last_played_at desc);

alter table public.trip_path_quests enable row level security;

drop policy if exists "tpq_select_own" on public.trip_path_quests;
create policy "tpq_select_own" on public.trip_path_quests
  for select using (auth.uid() = user_id);

drop policy if exists "tpq_write_own" on public.trip_path_quests;
create policy "tpq_write_own" on public.trip_path_quests
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
