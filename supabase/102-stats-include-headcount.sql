-- WFA update: the partners page's attendance numbers (average attendance, and by event type) include the headcount
-- officers add for people who came but didn't check in (Officer tools -> Attendance).
-- Same as 85-hosted-events-and-stats.sql otherwise. Run once in Supabase -> SQL Editor, after 101. Safe to run again.

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
    select (select count(*) from attendance a join held h on h.id = a.event_id)
         + (select coalesce(sum(hc.extra), 0) from event_headcount hc join held h on h.id = hc.event_id) as n
  ),
  per_event as (
    select h.id, h.cat, (select count(*) from attendance a where a.event_id = h.id)
      + coalesce((select hc.extra from event_headcount hc where hc.event_id = h.id), 0) as n from held h
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
