-- WFA update (October 2026): new event types, multiple majors + minor,
-- officer ranks and branches, officers off the leaderboard, hidden officer meetings.
-- Paste into Supabase -> SQL Editor -> New query, then Run. Safe to run once.

-- ============ Event types ============
alter table public.events drop constraint if exists events_cat_check;
update public.events set cat = case cat
  when 'speaker' then 'guest_speaker'
  when 'competition' then 'case_competition'
  when 'meeting' then 'social'
  else cat end;
alter table public.events alter column cat set default 'workshop';
alter table public.events add constraint events_cat_check check (cat in
  ('case_competition', 'career_fair', 'guest_speaker', 'excursion', 'workshop', 'social', 'officer_meeting'));

create or replace function public.event_points(c text) returns int
language sql immutable as $$
  select case c
    when 'case_competition' then 25 when 'career_fair' then 25 when 'excursion' then 25
    when 'guest_speaker' then 15 when 'workshop' then 10 when 'social' then 10
    else 0 end
$$;

-- Officer meetings: only officers and admins can see them.
drop policy if exists "anyone reads events" on public.events;
create policy "anyone reads events" on public.events for select
  using (cat <> 'officer_meeting' or is_officer());

create or replace function public.event_stats()
returns table (event_id uuid, rsvps int, attended int)
language sql stable security definer set search_path = public as $$
  select e.id,
    (select count(*) from rsvps r where r.event_id = e.id)::int,
    (select count(*) from attendance a where a.event_id = e.id)::int
  from events e
  where e.cat <> 'officer_meeting' or is_officer()
$$;

-- ============ Multiple majors and a minor ============
alter table public.members add column if not exists majors text[] not null default '{}';
alter table public.members add column if not exists minor text not null default '';
update public.members set majors = array[major] where major <> '' and majors = '{}';

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare m text[];
begin
  if jsonb_typeof(new.raw_user_meta_data -> 'majors') = 'array' then
    m := array(select jsonb_array_elements_text(new.raw_user_meta_data -> 'majors'));
  elsif coalesce(new.raw_user_meta_data ->> 'major', '') <> '' then
    m := array[new.raw_user_meta_data ->> 'major'];
  else
    m := '{}';
  end if;
  insert into members (id, email, uvuid, first, last, major, majors, minor)
  values (new.id, lower(new.email),
          coalesce(new.raw_user_meta_data ->> 'uvuid', ''),
          coalesce(new.raw_user_meta_data ->> 'first', ''),
          coalesce(new.raw_user_meta_data ->> 'last', ''),
          coalesce(m[1], ''), m,
          coalesce(new.raw_user_meta_data ->> 'minor', ''));
  return new;
end $$;

-- ============ Leaderboard: members only, new point values ============
create or replace function public.leaderboard()
returns table (email text, first text, last text, major text, events int, points int)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  return query
    select case when m.email = jwt_email() then m.email else null end,
      m.first, m.last, array_to_string(m.majors, ', '),
      count(e.id)::int,
      coalesce(sum(event_points(e.cat)), 0)::int
    from members m
    left join attendance a on a.email = m.email
    left join events e on e.id = a.event_id and e.cat <> 'officer_meeting'
    where not exists (select 1 from access_list al where al.email = m.email)
    group by m.email, m.first, m.last, m.majors;
end $$;

-- ============ Officer ranks and branches ============
alter table public.officer_profiles add column if not exists tier text not null default 'officer';
alter table public.officer_profiles add column if not exists branch text not null default '';
alter table public.officer_profiles drop constraint if exists officer_profiles_tier_check;
alter table public.officer_profiles add constraint officer_profiles_tier_check check (tier in ('president', 'officer'));
alter table public.officer_profiles drop constraint if exists officer_profiles_branch_check;
alter table public.officer_profiles add constraint officer_profiles_branch_check
  check (branch in ('', 'communications', 'operations', 'financial_applications'));

drop view if exists public.officers_public;
create view public.officers_public as
  select p.*, a.role from public.officer_profiles p join public.access_list a using (email);
grant select on public.officers_public to anon, authenticated;

update public.officer_profiles set tier = 'president', branch = 'operations' where email = 'paula.gaona@uvu.edu';
