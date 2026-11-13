-- WFA update: events hosted by another organization (84) have no WFA check-in, so no attendance or points, and are
-- left out of statistics. Any event can also be left out of statistics ("Count this event in statistics" off).
-- Run once in Supabase -> SQL Editor, after 84-event-host.sql. Safe to run again.

alter table public.events add column if not exists in_stats boolean not null default true;

-- No check-in for events run by another organization: a registration link (82) or a host (84).
create or replace function public.checkin_mode_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from events e where e.id = new.event_id and (e.reg_mode = 'link' or coalesce(e.host, '') <> '')) then
    raise exception 'This event is run by another organization, so there''s no WFA check-in.';
  end if;
  return new;
end $$;

-- Whether an event counts in statistics.
create or replace function public.counts_in_stats(e events) returns boolean
language sql stable as $$
  select e.in_stats and coalesce(e.host, '') = '' and coalesce(e.reg_mode, 'rsvp') <> 'link'
$$;

-- Same as 79-top-majors-relevant-and-other.sql, leaving out events that don't count in statistics.
create or replace function public.public_stats()
returns json language sql stable security definer set search_path = public as $$
  with m as (
    select * from members where not exists (select 1 from test_accounts t where t.email = members.email)
  ),
  held as (
    select e.id, e.cat from events e
    where (e.date + e.end_time) at time zone 'America/Denver' <= now()
      and e.cat <> 'officer_meeting' and not e.draft and not e.test and public.counts_in_stats(e)
  ),
  checkins as (
    select count(*) as n from attendance a join held h on h.id = a.event_id
  ),
  per_event as (
    select h.id, h.cat, (select count(*) from attendance a where a.event_id = h.id) as n from held h
  ),
  major_counts as (
    select maj as name, count(*) as n,
      (count(*) >= 3
        or maj in ('Finance, M.S.', 'Master of Business Administration, M.B.A.', 'Strategic Foresight and Business, B.S.')
        or maj ilike 'Mathematics%Actuarial%') as shown
    from m, unnest(m.majors) maj
    group by maj
  )
  select json_build_object(
    'members', (select count(*) from m),
    'events', (select count(*) from held),
    'avg_attendance', (select case when (select count(*) from held) = 0 then 0
                         else round((select n from checkins)::numeric / (select count(*) from held)) end),
    'by_type', (select coalesce(json_agg(x order by x.avg desc), '[]') from (
        select cat, count(*) as events, round(avg(n))::int as avg from per_event group by cat) x),
    'answered', (select count(*) from m where cardinality(interests) > 0),
    'majors_answered', (select count(*) from m where cardinality(majors) > 0),
    'majors', (select coalesce(json_agg(x), '[]') from (
        select name, n from major_counts where shown order by n desc, name) x),
    'majors_other', (select coalesce(sum(n), 0)::int from major_counts where not shown),
    'interests', (select coalesce(json_agg(x), '[]') from (
        select i as name, count(*) as n from m, unnest(m.interests) i
        where i <> 'Not sure yet'
        group by i having count(*) >= 3 order by count(*) desc limit 8) x)
  );
$$;
grant execute on function public.public_stats() to anon, authenticated;
