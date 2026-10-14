-- ================================================================
-- Task Tracker — Supabase Setup Script v2
-- Run this entire script in: Supabase Dashboard → SQL Editor → New query
-- If you ran v1 before, this is safe to run again (uses IF NOT EXISTS)
-- ================================================================

-- ── 1. PROFILES ─────────────────────────────────────────────────
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  avatar_url  text,
  created_at  timestamptz default now()
);
alter table public.profiles enable row level security;
drop policy if exists "Authenticated users can view profiles" on public.profiles;
drop policy if exists "Users can update their own profile" on public.profiles;
create policy "Authenticated users can view profiles" on public.profiles for select to authenticated using (true);
create policy "Users can update their own profile" on public.profiles for update to authenticated using (auth.uid() = id);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)))
  on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ── 2. CATEGORIES ───────────────────────────────────────────────
create table if not exists public.categories (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz default now(),
  unique(name)
);
insert into public.categories (name) values ('SCB'),('Internal'),('Admin'),('Personal') on conflict (name) do nothing;
alter table public.categories enable row level security;
drop policy if exists "Authenticated users can view categories" on public.categories;
drop policy if exists "Authenticated users can add categories" on public.categories;
drop policy if exists "Creators can delete their categories" on public.categories;
create policy "Authenticated users can view categories" on public.categories for select to authenticated using (true);
create policy "Authenticated users can add categories" on public.categories for insert to authenticated with check (true);
create policy "Creators can delete their categories" on public.categories for delete to authenticated using (auth.uid() = created_by);

-- ── 3. PROJECTS ─────────────────────────────────────────────────
create table if not exists public.projects (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  description text,
  color       text default '#2563eb',
  created_by  uuid references auth.users(id) on delete cascade,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);
alter table public.projects enable row level security;
drop policy if exists "Members can view their projects" on public.projects;
drop policy if exists "Authenticated users can create projects" on public.projects;
drop policy if exists "Owners can update projects" on public.projects;
drop policy if exists "Owners can delete projects" on public.projects;
create policy "Members can view their projects" on public.projects for select to authenticated
  using (id in (select project_id from public.project_members where user_id = auth.uid()));
create policy "Authenticated users can create projects" on public.projects for insert to authenticated
  with check (auth.uid() = created_by);
create policy "Owners can update projects" on public.projects for update to authenticated
  using (id in (select project_id from public.project_members where user_id = auth.uid() and role = 'owner'));
create policy "Owners can delete projects" on public.projects for delete to authenticated
  using (auth.uid() = created_by);

-- ── 4. PROJECT MEMBERS ──────────────────────────────────────────
create table if not exists public.project_members (
  id          uuid primary key default gen_random_uuid(),
  project_id  uuid references public.projects(id) on delete cascade,
  user_id     uuid references auth.users(id) on delete cascade,
  role        text not null default 'member' check (role in ('owner','member')),
  invited_by  uuid references auth.users(id) on delete set null,
  joined_at   timestamptz default now(),
  unique(project_id, user_id)
);
alter table public.project_members enable row level security;
drop policy if exists "Members can view project membership" on public.project_members;
drop policy if exists "Members can add members" on public.project_members;
drop policy if exists "Owners can remove members" on public.project_members;
create policy "Members can view project membership" on public.project_members for select to authenticated
  using (project_id in (select project_id from public.project_members pm2 where pm2.user_id = auth.uid()));
create policy "Members can add members" on public.project_members for insert to authenticated
  with check (project_id in (select project_id from public.project_members pm2 where pm2.user_id = auth.uid()));
create policy "Owners can remove members" on public.project_members for delete to authenticated
  using (project_id in (select project_id from public.project_members pm2 where pm2.user_id = auth.uid() and pm2.role = 'owner'));

-- ── 5. PROJECT INVITES ──────────────────────────────────────────
create table if not exists public.project_invites (
  id          uuid primary key default gen_random_uuid(),
  project_id  uuid references public.projects(id) on delete cascade,
  email       text,
  token       text unique not null default encode(gen_random_bytes(24), 'hex'),
  invited_by  uuid references auth.users(id) on delete set null,
  status      text not null default 'pending' check (status in ('pending','accepted','declined')),
  created_at  timestamptz default now(),
  expires_at  timestamptz default now() + interval '7 days'
);
alter table public.project_invites enable row level security;
drop policy if exists "Members can view invites for their projects" on public.project_invites;
drop policy if exists "Members can create invites" on public.project_invites;
drop policy if exists "Anyone can read invite by token" on public.project_invites;
drop policy if exists "Invitee can update invite status" on public.project_invites;
create policy "Members can view invites for their projects" on public.project_invites for select to authenticated
  using (project_id in (select project_id from public.project_members where user_id = auth.uid())
         or token = current_setting('request.jwt.claims', true)::json->>'invite_token');
create policy "Members can create invites" on public.project_invites for insert to authenticated
  with check (project_id in (select project_id from public.project_members where user_id = auth.uid()));
create policy "Anyone can read invite by token" on public.project_invites for select to anon using (true);
create policy "Invitee can update invite status" on public.project_invites for update to authenticated using (true);

-- ── 6. TASKS ────────────────────────────────────────────────────
create table if not exists public.tasks (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  priority    text not null default 'med' check (priority in ('high','med','low')),
  category    text not null default 'Personal',
  due         date,
  notes       text,
  done        boolean not null default false,
  parent_id   uuid references public.tasks(id) on delete set null,
  project_id  uuid references public.projects(id) on delete set null,
  recur_group uuid,
  recur_label text,
  recur_index int,
  recur_total int,
  attachments jsonb default '[]'::jsonb,
  created_by  uuid references auth.users(id) on delete cascade,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);
alter table public.tasks enable row level security;
drop policy if exists "Users can view own and project tasks" on public.tasks;
drop policy if exists "Users can insert tasks" on public.tasks;
drop policy if exists "Creators can update tasks" on public.tasks;
drop policy if exists "Creators can delete tasks" on public.tasks;
create policy "Users can view own and project tasks" on public.tasks for select to authenticated
  using (
    created_by = auth.uid()
    or (project_id is not null and project_id in (
      select project_id from public.project_members where user_id = auth.uid()
    ))
  );
create policy "Users can insert tasks" on public.tasks for insert to authenticated
  with check (auth.uid() = created_by);
create policy "Creators can update tasks" on public.tasks for update to authenticated
  using (auth.uid() = created_by);
create policy "Creators can delete tasks" on public.tasks for delete to authenticated
  using (auth.uid() = created_by);

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;
drop trigger if exists set_tasks_updated_at on public.tasks;
create trigger set_tasks_updated_at before update on public.tasks
  for each row execute procedure public.set_updated_at();
drop trigger if exists set_projects_updated_at on public.projects;
create trigger set_projects_updated_at before update on public.projects
  for each row execute procedure public.set_updated_at();

-- ── 7. NOTES ────────────────────────────────────────────────────
create table if not exists public.notes (
  id            uuid primary key default gen_random_uuid(),
  title         text,
  content       text,
  source_type   text default 'text' check (source_type in ('text','image','document','audio')),
  attachments   jsonb default '[]'::jsonb,
  project_id    uuid references public.projects(id) on delete set null,
  created_by    uuid references auth.users(id) on delete cascade,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);
alter table public.notes enable row level security;
drop policy if exists "Users can view own and project notes" on public.notes;
drop policy if exists "Users can insert notes" on public.notes;
drop policy if exists "Creators can update notes" on public.notes;
drop policy if exists "Creators can delete notes" on public.notes;
create policy "Users can view own and project notes" on public.notes for select to authenticated
  using (
    created_by = auth.uid()
    or (project_id is not null and project_id in (
      select project_id from public.project_members where user_id = auth.uid()
    ))
  );
create policy "Users can insert notes" on public.notes for insert to authenticated
  with check (auth.uid() = created_by);
create policy "Creators can update notes" on public.notes for update to authenticated
  using (auth.uid() = created_by);
create policy "Creators can delete notes" on public.notes for delete to authenticated
  using (auth.uid() = created_by);

drop trigger if exists set_notes_updated_at on public.notes;
create trigger set_notes_updated_at before update on public.notes
  for each row execute procedure public.set_updated_at();

-- ── 8. REALTIME ─────────────────────────────────────────────────
alter publication supabase_realtime add table public.tasks;
alter publication supabase_realtime add table public.categories;
alter publication supabase_realtime add table public.projects;
alter publication supabase_realtime add table public.project_members;
alter publication supabase_realtime add table public.notes;

-- ── DONE ─────────────────────────────────────────────────────────
-- After running: go to Supabase Settings → API
-- Copy Project URL (https://xxx.supabase.co) and anon/public key
-- Paste into index.html setup screen
