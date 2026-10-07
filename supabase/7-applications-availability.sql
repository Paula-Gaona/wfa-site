-- WFA update: officer applications and weekly availability.
-- Paste into Supabase -> SQL Editor -> New query, then Run.

-- ============ Officer application settings ============
create table public.app_settings (
  id int primary key default 1 check (id = 1),
  open boolean not null default false,
  branches text[] not null default '{}',
  deadline date,
  opened_at timestamptz          -- start of the current application round
);
insert into public.app_settings (id) values (1);
alter table public.app_settings enable row level security;
create policy "anyone reads application settings" on public.app_settings for select using (true);
create policy "admins change application settings" on public.app_settings for update using (is_admin());

create or replace function public.apps_open() returns boolean
language sql stable security definer set search_path = public as $$
  select open and cardinality(branches) > 0
     and (deadline is null or deadline >= (now() at time zone 'America/Denver')::date)
  from app_settings where id = 1
$$;

-- ============ Applications ============
create table public.applications (
  id uuid primary key default gen_random_uuid(),
  email text not null default public.jwt_email(),
  cycle timestamptz not null,    -- which application round this belongs to
  branches text[] not null,      -- in order of preference
  year text not null,
  grad text not null,
  why text not null,
  ideas text not null,
  resume_path text not null default '',
  linkedin text not null default '',
  other text not null default '',
  status text not null default 'new' check (status in ('new', 'interviewing', 'accepted', 'declined')),
  notes text not null default '',  -- private admin notes
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index applications_one_per_round on public.applications (email, cycle);
alter table public.applications enable row level security;
create policy "applicant or admin reads applications" on public.applications for select
  using (email = jwt_email() or is_admin());
create policy "members apply while open" on public.applications for insert
  with check (auth.uid() is not null and email = jwt_email() and apps_open()
    and cycle = (select opened_at from app_settings where id = 1)
    and cardinality(branches) > 0
    and branches <@ (select branches from app_settings where id = 1)
    and status = 'new' and notes = '');
create policy "admins review applications" on public.applications for update using (is_admin());
create policy "admins delete applications" on public.applications for delete using (is_admin());

-- Resumes: private. Applicants upload into their own folder; only they and admins can open them.
insert into storage.buckets (id, name, public) values ('resumes', 'resumes', false)
  on conflict (id) do nothing;
create policy "members upload own resume" on storage.objects for insert to authenticated
  with check (bucket_id = 'resumes' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "own or admin reads resumes" on storage.objects for select to authenticated
  using (bucket_id = 'resumes' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
create policy "own or admin deletes resumes" on storage.objects for delete to authenticated
  using (bucket_id = 'resumes' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- ============ Weekly availability ============
create table public.availability (
  email text primary key default public.jwt_email(),
  slots text[] not null default '{}',   -- e.g. 'tue-16' = Tuesday 4-6 PM
  updated_at timestamptz not null default now()
);
alter table public.availability enable row level security;
create policy "self or officers read availability" on public.availability for select
  using (email = jwt_email() or is_officer());
create policy "members save own availability" on public.availability for insert
  with check (auth.uid() is not null and email = jwt_email());
create policy "members update own availability" on public.availability for update
  using (email = jwt_email());

-- ============ Faculty advisors, and honorary officers (officer permissions, hidden from the public Officers page) ============
alter table public.officer_profiles drop constraint if exists officer_profiles_tier_check;
alter table public.officer_profiles add constraint officer_profiles_tier_check
  check (tier in ('president', 'vice_president', 'advisor', 'officer', 'honorary'));

drop view if exists public.officers_public;
create view public.officers_public as
  select p.*, a.role,
    coalesce(m.majors, '{}') as majors,
    coalesce(m.minor, '') as minor
  from public.officer_profiles p
  join public.access_list a using (email)
  left join public.members m on m.email = p.email
  where p.tier <> 'honorary' or public.is_officer();   -- the public never sees honorary officers
grant select on public.officers_public to anon, authenticated;

-- ============ Removing a member also removes these ============
create or replace function public.remove_member(p_email text) returns text
language plpgsql security definer set search_path = public as $$
declare e text := lower(trim(p_email)); uid uuid;
begin
  if not is_admin() then raise exception 'Only admins can remove members.'; end if;
  if e = jwt_email() then raise exception 'You can''t remove your own account.'; end if;

  delete from access_list where email = e;
  delete from officer_profiles where email = e;
  delete from rsvps where email = e;
  delete from attendance where email = e;
  delete from dues where email = e;
  delete from applications where email = e;
  delete from availability where email = e;

  select id into uid from members where email = e;
  if uid is not null then delete from auth.users where id = uid; end if;

  insert into change_log (who, text) values (jwt_email(), 'Removed member ' || e);
  return 'ok';
end $$;
