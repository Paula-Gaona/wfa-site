-- WFA update: an "Other" event type, where officers set how many points it's worth on the event.
-- Run once in Supabase -> SQL Editor, after 104. Safe to run again.

alter table public.events add column if not exists points int;   -- only used by "Other" events
alter table public.events drop constraint if exists events_points_check;
alter table public.events add constraint events_points_check check (points is null or points between 0 and 100);

alter table public.events drop constraint if exists events_cat_check;
alter table public.events add constraint events_cat_check check (cat in
  ('case_competition', 'career_fair', 'guest_speaker', 'panel', 'excursion', 'workshop', 'social', 'other', 'officer_meeting'));

-- An event's points: its type's points, or the amount set on the event for "Other".
create or replace function public.event_points_of(p_cat text, p_points int) returns int
language sql immutable as $$
  select case when p_cat = 'other' then coalesce(p_points, 0) else event_points(p_cat) end
$$;

-- Leaderboard standings: same as 37-case-competition-teams.sql, with "Other" events' own points.
create or replace function public.lb_standings(since timestamptz, until timestamptz)
returns table (email text, first text, last text, major text, events int, points int, anon boolean)
language sql stable security definer set search_path = public as $$
  select m.email, m.first, m.last, array_to_string(m.majors, ' & '),
    coalesce(att.n, 0)::int,
    (coalesce(att.p, 0) + coalesce(aw.p, 0) + 2 * coalesce(sv.n, 0) + coalesce(pl.p, 0))::int,
    not m.lb_public
  from members m
  left join (
    select a.email, count(e.id) as n, sum(event_points_of(e.cat, e.points)) as p
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
  left join (
    select cm.email, sum(placement_points(t.placement)) as p
    from case_teams t join case_team_members cm on cm.team_id = t.id and cm.confirmed
    where t.placement is not null and (since is null or t.placed_at >= since) and (until is null or t.placed_at < until)
    group by cm.email) pl on pl.email = m.email
  where not exists (select 1 from access_list al where al.email = m.email)
    and exists (select 1 from test_accounts t where t.email = m.email) = public.is_test()
    and not exists (select 1 from test_accounts t where t.email = m.email and t.role = 'admin');
$$;
revoke execute on function public.lb_standings(timestamptz, timestamptz) from public, anon, authenticated;
