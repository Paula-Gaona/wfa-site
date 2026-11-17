-- WFA update: officer roles for each event (setup, check-in, MC, cleanup, ...): what the job is, how early to
-- arrive, how many people, and which officers are on it. Officers see and edit them on the event page; the
-- automatic emails send each assigned officer their instructions the day before.
-- Run once in Supabase -> SQL Editor. Safe to run again.

create table if not exists public.event_roles (
  event_id uuid primary key references public.events(id) on delete cascade,
  roles jsonb not null default '[]'::jsonb,
  updated_by text not null default '',
  updated_at timestamptz not null default now()
);
alter table public.event_roles drop constraint if exists event_roles_is_list;
alter table public.event_roles add constraint event_roles_is_list check (jsonb_typeof(roles) = 'array' and jsonb_array_length(roles) <= 40);

alter table public.event_roles enable row level security;
drop policy if exists "officers read event roles" on public.event_roles;
create policy "officers read event roles" on public.event_roles for select using (is_officer());
drop policy if exists "officers add event roles" on public.event_roles;
create policy "officers add event roles" on public.event_roles for insert with check (is_officer());
drop policy if exists "officers edit event roles" on public.event_roles;
create policy "officers edit event roles" on public.event_roles for update using (is_officer()) with check (is_officer());
drop policy if exists "officers delete event roles" on public.event_roles;
create policy "officers delete event roles" on public.event_roles for delete using (is_officer());

-- The usual roles: what "Add the usual roles" fills in on an event. One shared list that officers can edit.
-- Empty until someone saves it; until then the site uses its built-in list.
create table if not exists public.role_presets (
  id int primary key default 1 check (id = 1),
  roles jsonb not null default '[]'::jsonb check (jsonb_typeof(roles) = 'array' and jsonb_array_length(roles) <= 40),
  updated_by text not null default '',
  updated_at timestamptz not null default now()
);
alter table public.role_presets enable row level security;
drop policy if exists "officers read role presets" on public.role_presets;
create policy "officers read role presets" on public.role_presets for select using (is_officer());
drop policy if exists "officers add role presets" on public.role_presets;
create policy "officers add role presets" on public.role_presets for insert with check (is_officer());
drop policy if exists "officers edit role presets" on public.role_presets;
create policy "officers edit role presets" on public.role_presets for update using (is_officer()) with check (is_officer());
