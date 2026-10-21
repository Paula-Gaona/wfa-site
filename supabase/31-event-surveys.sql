-- WFA update: post-event surveys.
-- Members who checked in to an event can rate it (1-5 stars) and leave thoughts, from when the event ends until
-- 7 days later, and edit their answer while it's open. They choose anonymous or named. Each survey earns
-- 2 leaderboard points. Officers see results (anonymous ones without names) and can download them.
-- Run once in Supabase -> SQL Editor, after 30-point-awards.sql. Safe to run again.

create table if not exists public.event_surveys (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  email text not null default public.jwt_email(),
  rating int not null check (rating between 1 and 5),
  comment text not null default '' check (char_length(comment) <= 2000),
  anonymous boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (event_id, email)
);
alter table public.event_surveys enable row level security;

-- Open from the event's end (Mountain Time) until 7 days later, and only for people who checked in.
create or replace function public.survey_open(ev uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from events e join attendance a on a.event_id = e.id and a.email = public.jwt_email()
    where e.id = ev
      and now() >= (e.date + e.end_time) at time zone 'America/Denver'
      and now() <  (e.date + e.end_time) at time zone 'America/Denver' + interval '7 days');
$$;
grant execute on function public.survey_open(uuid) to authenticated;

-- Members see and change only their own answers, and only while the survey is open.
drop policy if exists "members read own surveys" on public.event_surveys;
create policy "members read own surveys" on public.event_surveys for select using (email = jwt_email());
drop policy if exists "members answer open surveys" on public.event_surveys;
create policy "members answer open surveys" on public.event_surveys for insert with check (email = jwt_email() and survey_open(event_id));
drop policy if exists "members edit open surveys" on public.event_surveys;
create policy "members edit open surveys" on public.event_surveys for update
  using (email = jwt_email() and survey_open(event_id)) with check (email = jwt_email() and survey_open(event_id));
-- Explicit grants (required for new tables from Oct 30, 2026). The policies above still decide access.
grant select, insert, update on public.event_surveys to authenticated;
grant select, insert, update, delete on public.event_surveys to service_role;

-- Officers read results here. Anonymous answers come back without a name or email.
create or replace function public.survey_results()
returns table (event_id uuid, rating int, comment text, anonymous boolean, email text, first text, last text, created_at timestamptz, updated_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_officer() then return; end if;
  return query
    select s.event_id, s.rating, s.comment, s.anonymous,
      case when s.anonymous then null else s.email end,
      case when s.anonymous then null else m.first end,
      case when s.anonymous then null else m.last end,
      s.created_at, s.updated_at
    from event_surveys s left join members m on m.email = s.email
    order by s.created_at;
end $$;
grant execute on function public.survey_results() to authenticated;

-- Leaderboard: each completed survey is worth 2 points, counted in the season it was first submitted.
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
  where not exists (select 1 from access_list al where al.email = m.email);
$$;
revoke execute on function public.lb_standings(timestamptz, timestamptz) from public, anon, authenticated;
