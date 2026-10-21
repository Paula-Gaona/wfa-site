-- WFA update: the member count on the Partner with us page includes officers and admins with accounts.
-- (Test accounts are still left out. The majors and career-interest breakdowns stay members-only.)
-- Run once in Supabase -> SQL Editor, after 35. Safe to run again.

create or replace function public.public_stats()
returns json language sql stable security definer set search_path = public as $$
  with everyone as (
    select * from members where not exists (select 1 from test_accounts t where t.email = members.email)
  ),
  m as (
    select * from everyone where not exists (select 1 from access_list a where a.email = everyone.email)
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
    'members', (select count(*) from everyone),
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
