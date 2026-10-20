-- WFA update: "Partner with us" page for firms and industry professionals.
-- Run once in Supabase -> SQL Editor (after 17-questions.sql). Safe to run again.

-- Partner inquiries go into the same Questions inbox, with a few extra fields.
alter table public.questions add column if not exists kind text not null default 'question';
alter table public.questions add column if not exists company text not null default '';
alter table public.questions add column if not exists job_title text not null default '';
alter table public.questions add column if not exists ways text[] not null default '{}';
alter table public.questions drop constraint if exists questions_kind_check;
alter table public.questions add constraint questions_kind_check check (kind in ('question', 'partner'));
alter table public.questions drop constraint if exists questions_partner_len;
alter table public.questions add constraint questions_partner_len
  check (char_length(company) <= 160 and char_length(job_title) <= 160 and cardinality(ways) <= 12);

-- Public member stats: totals only, never names or emails. Officers are left out.
-- Majors and interests with fewer than 3 members are hidden so no one can be singled out.
create or replace function public.public_stats()
returns json language sql stable security definer set search_path = public as $$
  with m as (
    select * from members where not exists (select 1 from access_list a where a.email = members.email)
  ),
  held as (
    select e.id from events e
    where e.date <= current_date and e.cat <> 'officer_meeting' and not e.draft
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
