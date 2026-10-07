-- ================================================================
-- Task Tracker — Supabase Setup Script
-- Run this entire script in: Supabase Dashboard → SQL Editor → New query
-- ================================================================

-- ── 1. CATEGORIES TABLE ──────────────────────────────────────────
create table if not exists public.categories (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz default now(),
  unique(name)
);

-- Seed built-in categories
insert into public.categories (name) values
  ('SCB'), ('Internal'), ('Admin'), ('Personal')
on conflict (name) do nothing;

-- ── 2. TASKS TABLE ───────────────────────────────────────────────
create table if not exists public.tasks (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  priority    text not null default 'med' check (priority in ('high','med','low')),
  category    text not null default 'Personal',
  due         date,
  notes       text,
  done        boolean not null default false,
  parent_id   uuid references public.tasks(id) on delete set null,
  recur_group uuid,
  recur_label text,
  recur_index int,
  recur_total int,
  attachments jsonb default '[]'::jsonb,
  created_by  uuid references auth.users(id) on delete cascade,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

-- ── 3. USER PROFILES TABLE ───────────────────────────────────────
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  avatar_url  text,
  created_at  timestamptz default now()
);

-- Auto-create profile on signup
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)));
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- Auto-update updated_at on tasks
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

drop trigger if exists set_tasks_updated_at on public.tasks;
create trigger set_tasks_updated_at
  before update on public.tasks
  for each row execute procedure public.set_updated_at();

-- ── 4. ROW LEVEL SECURITY ────────────────────────────────────────
-- Tasks: all authenticated users can see all tasks; only creator can edit/delete
alter table public.tasks enable row level security;

create policy "Authenticated users can view all tasks"
  on public.tasks for select
  to authenticated using (true);

create policy "Users can insert their own tasks"
  on public.tasks for insert
  to authenticated with check (auth.uid() = created_by);

create policy "Creators can update their own tasks"
  on public.tasks for update
  to authenticated using (auth.uid() = created_by);

create policy "Creators can delete their own tasks"
  on public.tasks for delete
  to authenticated using (auth.uid() = created_by);

-- Categories: all authenticated users can read and insert
alter table public.categories enable row level security;

create policy "Authenticated users can view categories"
  on public.categories for select
  to authenticated using (true);

create policy "Authenticated users can add categories"
  on public.categories for insert
  to authenticated with check (true);

create policy "Creators can delete their categories"
  on public.categories for delete
  to authenticated using (auth.uid() = created_by);

-- Profiles: users can read all profiles, only update their own
alter table public.profiles enable row level security;

create policy "Authenticated users can view profiles"
  on public.profiles for select
  to authenticated using (true);

create policy "Users can update their own profile"
  on public.profiles for update
  to authenticated using (auth.uid() = id);

-- ── 5. REALTIME ──────────────────────────────────────────────────
-- Enable realtime so all users see live updates
alter publication supabase_realtime add table public.tasks;
alter publication supabase_realtime add table public.categories;

-- ── DONE ─────────────────────────────────────────────────────────
-- After running this script:
-- 1. Go to Supabase Dashboard → Settings → API
-- 2. Copy your Project URL and anon/public key
-- 3. Paste them into the CONFIG section at the top of index.html
