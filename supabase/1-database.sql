-- Wolverine Finance Association: database setup
-- Paste this whole file into Supabase → SQL Editor → New query, then click Run.
-- Safe to run once on a new project.

-- ============ Helpers ============
create or replace function public.jwt_email() returns text
language sql stable as $$ select lower(coalesce(auth.jwt() ->> 'email', '')) $$;

-- ============ Tables ============
create table public.settings (
  id int primary key default 1 check (id = 1),
  semester text not null default 'Fall 2026',
  dues numeric not null default 0
);

-- Who is an admin or officer. Everyone else with an account is a member.
create table public.access_list (
  email text primary key check (email = lower(email)),
  role text not null check (role in ('admin', 'officer')),
  created_at timestamptz not null default now()
);

create table public.officer_profiles (
  email text primary key check (email = lower(email)),
  name text not null default '',
  title text not null default '',
  bio text not null default '',
  contact text not null default '',
  hours text not null default '',
  linkedin text not null default ''
);

create table public.members (
  id uuid primary key references auth.users (id) on delete cascade,
  email text not null unique,
  uvuid text not null default '',
  first text not null default '',
  last text not null default '',
  major text not null default '',
  joined date not null default current_date
);
create unique index members_uvuid_unique on public.members (uvuid) where uvuid <> '';

create table public.events (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  cat text not null default 'meeting' check (cat in ('meeting', 'speaker', 'workshop', 'competition', 'social')),
  date date not null,
  start_time time not null,
  end_time time not null,
  loc text not null default '',
  cap int not null default 0,
  descr text not null default '',
  created_at timestamptz not null default now()
);

create table public.checkin_codes (
  event_id uuid primary key references public.events (id) on delete cascade,
  code text not null
);

create table public.rsvps (
  event_id uuid not null references public.events (id) on delete cascade,
  email text not null default public.jwt_email(),
  created_at timestamptz not null default now(),
  primary key (event_id, email)
);

create table public.attendance (
  event_id uuid not null references public.events (id) on delete cascade,
  email text not null default public.jwt_email(),
  created_at timestamptz not null default now(),
  primary key (event_id, email)
);

create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text not null,
  aud text not null default 'all' check (aud in ('all', 'members')),
  pinned boolean not null default false,
  author text not null default public.jwt_email(),
  created_at timestamptz not null default now()
);

create table public.recaps (
  id uuid primary key default gen_random_uuid(),
  event_id uuid references public.events (id) on delete set null,
  title text not null,
  body text not null,
  photos text[] not null default '{}',
  author text not null default public.jwt_email(),
  created_at timestamptz not null default now()
);

create table public.archive (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  type text not null check (type in ('slides', 'recording', 'notes', 'template')),
  url text not null default '',
  event_id uuid references public.events (id) on delete set null,
  descr text not null default '',
  date date not null default current_date
);

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  event_id uuid references public.events (id) on delete set null,
  owner text not null,
  due date not null default current_date,
  done boolean not null default false
);

create table public.dues (
  email text primary key,
  status text not null check (status in ('paid', 'unpaid', 'waived')),
  updated date not null default current_date
);

create table public.change_log (
  id bigserial primary key,
  ts timestamptz not null default now(),
  who text not null default public.jwt_email(),
  text text not null
);

-- ============ Role functions ============
create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then 'guest'
    else coalesce((select role from access_list where email = jwt_email()), 'member') end
$$;
create or replace function public.is_officer() returns boolean
language sql stable as $$ select public.my_role() in ('officer', 'admin') $$;
create or replace function public.is_admin() returns boolean
language sql stable as $$ select public.my_role() = 'admin' $$;

-- Public officer list (the Officers page) without opening up the access list itself.
create view public.officers_public as
  select p.*, a.role from public.officer_profiles p join public.access_list a using (email);
grant select on public.officers_public to anon, authenticated;

-- ============ Triggers ============
-- Create a member row whenever someone signs up (or an admin creates an officer account).
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into members (id, email, uvuid, first, last, major)
  values (new.id, lower(new.email),
          coalesce(new.raw_user_meta_data ->> 'uvuid', ''),
          coalesce(new.raw_user_meta_data ->> 'first', ''),
          coalesce(new.raw_user_meta_data ->> 'last', ''),
          coalesce(new.raw_user_meta_data ->> 'major', ''));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Never let the club lose its last admin.
create or replace function public.guard_last_admin() returns trigger
language plpgsql as $$
begin
  if (tg_op = 'DELETE' and old.role = 'admin') or (tg_op = 'UPDATE' and old.role = 'admin' and new.role <> 'admin') then
    if (select count(*) from access_list where role = 'admin') <= 1 then
      raise exception 'Add another admin before removing the last one.';
    end if;
  end if;
  return coalesce(new, old);
end $$;
create trigger access_list_guard before update or delete on public.access_list
  for each row execute function public.guard_last_admin();

-- Close RSVPs when an event is full.
create or replace function public.check_capacity() returns trigger
language plpgsql security definer set search_path = public as $$
declare c int;
begin
  select cap into c from events where id = new.event_id;
  if c > 0 and (select count(*) from rsvps where event_id = new.event_id) >= c then
    raise exception 'This event is full.';
  end if;
  return new;
end $$;
create trigger rsvps_capacity before insert on public.rsvps
  for each row execute function public.check_capacity();

-- ============ Functions the site calls ============
-- RSVP and check-in counts for everyone, without exposing who RSVP'd.
create or replace function public.event_stats()
returns table (event_id uuid, rsvps int, attended int)
language sql stable security definer set search_path = public as $$
  select e.id,
    (select count(*) from rsvps r where r.event_id = e.id)::int,
    (select count(*) from attendance a where a.event_id = e.id)::int
  from events e
$$;

-- Leaderboard for signed-in members. Only your own email is returned.
create or replace function public.leaderboard()
returns table (email text, first text, last text, major text, events int, points int)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  return query
    select case when m.email = jwt_email() then m.email else null end,
      m.first, m.last, m.major,
      count(e.id)::int,
      coalesce(sum(case e.cat when 'competition' then 25 when 'workshop' then 15
                              when 'social' then 5 when 'meeting' then 10 when 'speaker' then 10 else 0 end), 0)::int
    from members m
    left join attendance a on a.email = m.email
    left join events e on e.id = a.event_id
    group by m.email, m.first, m.last, m.major;
end $$;

-- Members check in with the code on screen. Only works on the event's date (Utah time).
create or replace function public.check_in(p_event uuid, p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare d date; c text;
begin
  if auth.uid() is null then return 'signin'; end if;
  select e."date" into d from events e where e.id = p_event;
  if d is null then return 'missing'; end if;
  if d <> (now() at time zone 'America/Denver')::date then return 'closed'; end if;
  select code into c from checkin_codes where event_id = p_event;
  if c is null then return 'notstarted'; end if;
  if upper(trim(p_code)) <> c then return 'wrong'; end if;
  insert into attendance (event_id, email) values (p_event, jwt_email()) on conflict do nothing;
  return 'ok';
end $$;

-- ============ Row-level security ============
alter table public.settings enable row level security;
alter table public.access_list enable row level security;
alter table public.officer_profiles enable row level security;
alter table public.members enable row level security;
alter table public.events enable row level security;
alter table public.checkin_codes enable row level security;
alter table public.rsvps enable row level security;
alter table public.attendance enable row level security;
alter table public.announcements enable row level security;
alter table public.recaps enable row level security;
alter table public.archive enable row level security;
alter table public.tasks enable row level security;
alter table public.dues enable row level security;
alter table public.change_log enable row level security;

create policy "anyone reads settings" on public.settings for select using (true);
create policy "officers edit settings" on public.settings for update using (is_officer());

create policy "officers read access list" on public.access_list for select using (is_officer());
create policy "admins add to access list" on public.access_list for insert with check (is_admin());
create policy "admins change access list" on public.access_list for update using (is_admin());
create policy "admins remove from access list" on public.access_list for delete using (is_admin());

create policy "anyone reads officer profiles" on public.officer_profiles for select using (true);
create policy "admins or self add profile" on public.officer_profiles for insert with check (is_admin() or (email = jwt_email() and is_officer()));
create policy "admins or self edit profile" on public.officer_profiles for update using (is_admin() or email = jwt_email());
create policy "admins delete profiles" on public.officer_profiles for delete using (is_admin());

create policy "self or officers read members" on public.members for select using (id = auth.uid() or is_officer());
create policy "self or admins edit member" on public.members for update using (id = auth.uid() or is_admin());

create policy "anyone reads events" on public.events for select using (true);
create policy "officers add events" on public.events for insert with check (is_officer());
create policy "officers edit events" on public.events for update using (is_officer());
create policy "officers delete events" on public.events for delete using (is_officer());

create policy "officers manage codes" on public.checkin_codes for all using (is_officer()) with check (is_officer());

create policy "self or officers read rsvps" on public.rsvps for select using (email = jwt_email() or is_officer());
create policy "members rsvp for themselves" on public.rsvps for insert with check (auth.uid() is not null and email = jwt_email());
create policy "members cancel own rsvp" on public.rsvps for delete using (email = jwt_email());

create policy "self or officers read attendance" on public.attendance for select using (email = jwt_email() or is_officer());
create policy "officers mark attendance" on public.attendance for insert with check (is_officer());
create policy "officers remove attendance" on public.attendance for delete using (is_officer());

create policy "public or member announcements" on public.announcements for select using (aud = 'all' or auth.uid() is not null);
create policy "officers post announcements" on public.announcements for insert with check (is_officer());
create policy "officers edit announcements" on public.announcements for update using (is_officer());
create policy "officers delete announcements" on public.announcements for delete using (is_officer());

create policy "anyone reads recaps" on public.recaps for select using (true);
create policy "officers write recaps" on public.recaps for insert with check (is_officer());
create policy "officers delete recaps" on public.recaps for delete using (is_officer());

create policy "members read archive" on public.archive for select using (auth.uid() is not null);
create policy "officers add archive" on public.archive for insert with check (is_officer());
create policy "officers delete archive" on public.archive for delete using (is_officer());

create policy "officers manage tasks" on public.tasks for all using (is_officer()) with check (is_officer());

create policy "self or officers read dues" on public.dues for select using (email = jwt_email() or is_officer());
create policy "officers set dues" on public.dues for insert with check (is_officer());
create policy "officers change dues" on public.dues for update using (is_officer());

create policy "admins read log" on public.change_log for select using (is_admin());
create policy "officers write log" on public.change_log for insert with check (is_officer() and who = jwt_email());

-- ============ Recap photo storage ============
insert into storage.buckets (id, name, public) values ('recap-photos', 'recap-photos', true)
  on conflict (id) do nothing;
create policy "officers upload recap photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'recap-photos' and public.is_officer());
create policy "officers delete recap photos" on storage.objects for delete to authenticated
  using (bucket_id = 'recap-photos' and public.is_officer());

-- ============ Starting data ============
insert into public.settings (id, semester, dues) values (1, 'Fall 2026', 0);
insert into public.access_list (email, role) values ('paula.gaona@uvu.edu', 'admin');
insert into public.officer_profiles (email, name, title, contact, linkedin)
  values ('paula.gaona@uvu.edu', 'Paula Gaona', 'President of Operations', 'paula.gaona@uvu.edu',
          'https://www.linkedin.com/in/paula-y-gaona');
