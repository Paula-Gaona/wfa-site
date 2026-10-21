-- WFA update: test accounts.
-- An admin marks an email as a test admin or a test member (Admin -> Test accounts). Test accounts live in their own
-- "test world": events and announcements a test admin makes are only visible to test accounts, test RSVPs, check-ins,
-- surveys, and points only count there, and test accounts have their own leaderboard. They never show up in real
-- stats, member lists, emails, or the real leaderboard. In the database a test admin has no real officer or admin
-- powers, so it can't change anything real. Run once in Supabase -> SQL Editor, after 32. Safe to run again.

-- ---------- Who is a test account ----------
create table if not exists public.test_accounts (
  email text primary key check (email = lower(email)),
  role text not null check (role in ('admin', 'member')),
  created_at timestamptz not null default now()
);
alter table public.test_accounts enable row level security;

create or replace function public.is_test() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from test_accounts where email = public.jwt_email());
$$;
create or replace function public.is_test_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from test_accounts where email = public.jwt_email() and role = 'admin');
$$;
-- The site asks this to know whether to show the test admin the admin pages. Null for real accounts.
create or replace function public.my_test_role() returns text
language sql stable security definer set search_path = public as $$
  select role from test_accounts where email = public.jwt_email();
$$;
grant execute on function public.is_test() to authenticated, anon;
grant execute on function public.is_test_admin() to authenticated, anon;
grant execute on function public.my_test_role() to authenticated;

drop policy if exists "officers and test accounts read test list" on public.test_accounts;
create policy "officers and test accounts read test list" on public.test_accounts for select using (is_officer() or is_test());
drop policy if exists "admins add test accounts" on public.test_accounts;
create policy "admins add test accounts" on public.test_accounts for insert with check (
  is_admin() and not exists (select 1 from access_list a where a.email = test_accounts.email));
drop policy if exists "admins change test accounts" on public.test_accounts;
create policy "admins change test accounts" on public.test_accounts for update using (is_admin()) with check (is_admin());
drop policy if exists "admins remove test accounts" on public.test_accounts;
create policy "admins remove test accounts" on public.test_accounts for delete using (is_admin());
grant select, insert, update, delete on public.test_accounts to authenticated;
grant select, insert, update, delete on public.test_accounts to service_role;

-- ---------- Test events and announcements ----------
alter table public.events add column if not exists test boolean not null default false;
alter table public.announcements add column if not exists test boolean not null default false;

-- Rows made by a test account are always test rows, and a row never switches worlds.
create or replace function public.mark_test_row() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then new.test := public.is_test(); else new.test := old.test; end if;
  return new;
end $$;
drop trigger if exists events_mark_test on public.events;
create trigger events_mark_test before insert or update on public.events for each row execute function public.mark_test_row();
drop trigger if exists announcements_mark_test on public.announcements;
create trigger announcements_mark_test before insert or update on public.announcements for each row execute function public.mark_test_row();

-- Real accounts and visitors only ever see real rows; test accounts only see test rows.
drop policy if exists "test rows stay separate" on public.events;
create policy "test rows stay separate" on public.events as restrictive for all using (test = is_test()) with check (test = is_test());
drop policy if exists "test rows stay separate" on public.announcements;
create policy "test rows stay separate" on public.announcements as restrictive for all using (test = is_test()) with check (test = is_test());

-- The test admin manages test events (including drafts and officer meetings) and test announcements.
drop policy if exists "test admin reads test events" on public.events;
create policy "test admin reads test events" on public.events for select using (is_test_admin());
drop policy if exists "test admin adds test events" on public.events;
create policy "test admin adds test events" on public.events for insert with check (is_test_admin());
drop policy if exists "test admin edits test events" on public.events;
create policy "test admin edits test events" on public.events for update using (is_test_admin()) with check (is_test_admin());
drop policy if exists "test admin deletes test events" on public.events;
create policy "test admin deletes test events" on public.events for delete using (is_test_admin());
drop policy if exists "test admin posts test announcements" on public.announcements;
create policy "test admin posts test announcements" on public.announcements for insert with check (is_test_admin());
drop policy if exists "test admin edits test announcements" on public.announcements;
create policy "test admin edits test announcements" on public.announcements for update using (is_test_admin()) with check (is_test_admin());
drop policy if exists "test admin deletes test announcements" on public.announcements;
create policy "test admin deletes test announcements" on public.announcements for delete using (is_test_admin());

-- Check-in codes for test events.
drop policy if exists "test admin manages test codes" on public.checkin_codes;
create policy "test admin manages test codes" on public.checkin_codes for all
  using (is_test_admin() and exists (select 1 from events e where e.id = event_id and e.test))
  with check (is_test_admin() and exists (select 1 from events e where e.id = event_id and e.test));

-- The test admin sees test members' profiles, RSVPs, and check-ins, and can mark test attendance by hand.
drop policy if exists "test admin reads test members" on public.members;
create policy "test admin reads test members" on public.members for select
  using (is_test_admin() and email in (select t.email from test_accounts t));
drop policy if exists "test admin reads test rsvps" on public.rsvps;
create policy "test admin reads test rsvps" on public.rsvps for select
  using (is_test_admin() and email in (select t.email from test_accounts t));
drop policy if exists "test admin reads test attendance" on public.attendance;
create policy "test admin reads test attendance" on public.attendance for select
  using (is_test_admin() and email in (select t.email from test_accounts t));
drop policy if exists "test admin marks test attendance" on public.attendance;
create policy "test admin marks test attendance" on public.attendance for insert
  with check (is_test_admin() and email in (select t.email from test_accounts t) and exists (select 1 from events e where e.id = event_id and e.test));
drop policy if exists "test admin removes test attendance" on public.attendance;
create policy "test admin removes test attendance" on public.attendance for delete
  using (is_test_admin() and email in (select t.email from test_accounts t));

-- The test admin can award test points to test accounts.
drop policy if exists "test admin reads test awards" on public.point_awards;
create policy "test admin reads test awards" on public.point_awards for select
  using (is_test_admin() and email in (select t.email from test_accounts t));
drop policy if exists "test admin gives test awards" on public.point_awards;
create policy "test admin gives test awards" on public.point_awards for insert
  with check (is_test_admin() and awarded_by = jwt_email() and email in (select t.email from test_accounts t));

-- ---------- Functions that skip RLS, so they need the same separation ----------
-- Check-in: a test account can only check in to test events, and a real account only to real ones.
create or replace function public.check_in(p_event uuid, p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare d date; c text; t boolean;
begin
  if auth.uid() is null then return 'signin'; end if;
  select e."date", e.test into d, t from events e where e.id = p_event;
  if d is null or t <> public.is_test() then return 'missing'; end if;
  if d <> (now() at time zone 'America/Denver')::date then return 'closed'; end if;
  select code into c from checkin_codes where event_id = p_event;
  if c is null then return 'notstarted'; end if;
  if upper(trim(p_code)) <> c then return 'wrong'; end if;
  insert into attendance (event_id, email) values (p_event, jwt_email()) on conflict do nothing;
  return 'ok';
end $$;

create or replace function public.event_stats()
returns table (event_id uuid, rsvps int, attended int)
language sql stable security definer set search_path = public as $$
  select e.id,
    (select count(*) from rsvps r where r.event_id = e.id)::int,
    (select count(*) from attendance a where a.event_id = e.id)::int
  from events e
  where (e.cat <> 'officer_meeting' or is_officer() or is_test_admin()) and e.test = is_test()
$$;

-- Public member stats (Partner with us page) leave out test accounts and test events.
create or replace function public.public_stats()
returns json language sql stable security definer set search_path = public as $$
  with m as (
    select * from members where not exists (select 1 from access_list a where a.email = members.email)
      and not exists (select 1 from test_accounts t where t.email = members.email)
  ),
  held as (
    select e.id from events e
    where (e.date + e.end_time) at time zone 'America/Denver' <= now()
      and e.cat <> 'officer_meeting' and not e.draft and not e.test
  ),
  checkins as (
    select count(*) as n from attendance a join held h on h.id = a.event_id
  )
  select json_build_object(
    'members', (select count(*) from m),
    'events', (select count(*) from held),
    'avg_attendance', (select case when (select count(*) from held) = 0 then 0
                         else round((select n from checkins)::numeric / (select count(*) from held)) end),
    'answered', (select count(*) from m where cardinality(interests) > 0),
    'majors', (select coalesce(json_agg(x), '[]') from (
        select maj as name, count(*) as n from m, unnest(m.majors) maj
        group by maj having count(*) >= 3 order by count(*) desc limit 6) x),
    'interests', (select coalesce(json_agg(x), '[]') from (
        select i as name, count(*) as n from m, unnest(m.interests) i
        where i <> 'Not sure yet'
        group by i having count(*) >= 3 order by count(*) desc limit 8) x)
  );
$$;
grant execute on function public.public_stats() to anon, authenticated;

-- Leaderboard: real accounts see real members only; test accounts see a separate board of test members.
-- Admins (real or test) aren't ranked, same as now.
create or replace function public.lb_standings(since timestamptz, until timestamptz)
returns table (email text, first text, last text, major text, events int, points int, anon boolean)
language sql stable security definer set search_path = public as $$
  select m.email, m.first, m.last, array_to_string(m.majors, ' & '),
    coalesce(att.n, 0)::int,
    (coalesce(att.p, 0) + coalesce(aw.p, 0) + 2 * coalesce(sv.n, 0))::int,
    not m.lb_public
  from members m
  left join (
    select a.email, count(e.id) as n, sum(event_points(e.cat)) as p
    from attendance a join events e on e.id = a.event_id and e.cat <> 'officer_meeting'
    where (since is null or a.created_at >= since) and (until is null or a.created_at < until)
    group by a.email) att on att.email = m.email
  left join (
    select pa.email, sum(pa.points) as p from point_awards pa
    where (since is null or pa.created_at >= since) and (until is null or pa.created_at < until)
    group by pa.email) aw on aw.email = m.email
  left join (
    select s.email, count(*) as n from event_surveys s
    where (since is null or s.created_at >= since) and (until is null or s.created_at < until)
    group by s.email) sv on sv.email = m.email
  where not exists (select 1 from access_list al where al.email = m.email)
    and exists (select 1 from test_accounts t where t.email = m.email) = public.is_test()
    and not exists (select 1 from test_accounts t where t.email = m.email and t.role = 'admin');
$$;
revoke execute on function public.lb_standings(timestamptz, timestamptz) from public, anon, authenticated;

create or replace function public.leaderboard()
returns table (email text, first text, last text, major text, events int, points int, anon boolean)
language plpgsql stable security definer set search_path = public as $$
declare since timestamptz;
begin
  if auth.uid() is null then return; end if;
  select lb_since into since from settings where id = 1;
  return query
    select case when s.email = jwt_email() then s.email else null end,
      case when not s.anon or s.email = jwt_email() or is_officer() or is_test_admin() then s.first else 'Anonymous' end,
      case when not s.anon or s.email = jwt_email() or is_officer() or is_test_admin() then s.last else 'Member' end,
      case when not s.anon or s.email = jwt_email() or is_officer() or is_test_admin() then s.major else '' end,
      s.events, s.points, s.anon
    from lb_standings(since, null) s;
end $$;
grant execute on function public.leaderboard() to authenticated;

-- Survey results and reminders: real officers see real events; the test admin sees test events.
create or replace function public.survey_results()
returns table (event_id uuid, rating int, comment text, anonymous boolean, email text, first text, last text, created_at timestamptz, updated_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.is_officer() or public.is_test_admin()) then return; end if;
  return query
    select s.event_id, s.rating, s.comment, s.anonymous,
      case when s.anonymous then null else s.email end,
      case when s.anonymous then null else m.first end,
      case when s.anonymous then null else m.last end,
      s.created_at, s.updated_at
    from event_surveys s join events e on e.id = s.event_id and e.test = public.is_test()
    left join members m on m.email = s.email
    order by s.created_at;
end $$;
grant execute on function public.survey_results() to authenticated;

create or replace function public.survey_pending()
returns table (event_id uuid, email text)
language sql stable security definer set search_path = public as $$
  select a.event_id, a.email from attendance a join events e on e.id = a.event_id
  where (public.is_officer() or public.is_test_admin()) and e.test = public.is_test()
    and e.cat <> 'officer_meeting' and not e.draft
    and now() >= (e.date + e.end_time) at time zone 'America/Denver'
    and now() <  (e.date + e.end_time) at time zone 'America/Denver' + interval '7 days'
    and not exists (select 1 from event_surveys s where s.event_id = a.event_id and s.email = a.email);
$$;
grant execute on function public.survey_pending() to authenticated;
