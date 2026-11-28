-- WFA update: points for keeping a profile up to date, a "top choice" star on career interests, and job preferences.
-- A profile has five sections, each worth points once a semester (fall and spring; summer counts as spring):
--   year in school 1, majors and minor 1, career interests (with a top choice starred) 3, job preferences 3, resume 3.
-- A member earns a section's points by saving it, or by confirming it's still right, on My account or the Jobs page.
-- Members whose sections are already filled in get this semester's points for them when this is run.
-- Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.members add column if not exists interest_top text[] not null default '{}';   -- starred career interests (by name)
alter table public.members add column if not exists job_kinds text[] not null default '{}';      -- internship, full_time
alter table public.members add column if not exists job_places text[] not null default '{}';     -- UT, remote, any

create table if not exists public.profile_checks (
  email text not null,
  term date not null,                      -- the semester's first day (August 1 or January 1)
  section text not null check (section in ('year', 'majors', 'careers', 'jobs', 'resume')),
  points int not null,
  created_at timestamptz not null default now(),
  primary key (email, term, section)
);
alter table public.profile_checks enable row level security;
drop policy if exists "members read their profile checks" on public.profile_checks;
create policy "members read their profile checks" on public.profile_checks for select using (email = lower(jwt_email()) or is_officer());
grant select on public.profile_checks to authenticated;
grant select, insert, update, delete on public.profile_checks to service_role;

-- The semester a profile check counts for, going by today's date (Mountain Time). No summer semester: May to July is spring.
create or replace function public.profile_term() returns date
language sql stable as $$
  select make_date(extract(year from d)::int, case when extract(month from d) >= 8 then 8 else 1 end, 1)
  from (select (now() at time zone 'America/Denver')::date as d) x;
$$;
create or replace function public.profile_term_name() returns text
language sql stable as $$
  select case when extract(month from profile_term()) = 8 then 'Fall ' else 'Spring ' end || extract(year from profile_term())::int;
$$;

create or replace function public.profile_section_points(s text) returns int
language sql immutable as $$ select case s when 'year' then 1 when 'majors' then 1 when 'careers' then 3 when 'jobs' then 3 when 'resume' then 3 else 0 end; $$;
create or replace function public.profile_section_label(s text) returns text
language sql immutable as $$ select case s when 'year' then 'year in school' when 'majors' then 'majors and minor' when 'careers' then 'career interests' when 'jobs' then 'job preferences' when 'resume' then 'resume' else s end; $$;

-- Whether a section is filled in. p_strict: career interests need a top choice starred (not asked of people who filled it in before stars existed).
create or replace function public.profile_section_filled(m public.members, s text, p_strict boolean default true) returns boolean
language sql stable as $$
  select case s
    when 'year' then coalesce(m.year, '') <> ''
    when 'majors' then coalesce(cardinality(m.majors), 0) > 0 or coalesce(m.major, '') <> ''
    when 'careers' then coalesce(cardinality(m.interests), 0) > 0
      and (not p_strict or coalesce(cardinality(m.interest_top), 0) > 0 or m.interests = array['Not sure yet'])
    when 'jobs' then coalesce(cardinality(m.job_kinds), 0) > 0 and coalesce(cardinality(m.job_places), 0) > 0
    when 'resume' then coalesce(m.resume_path, '') <> ''
    else false end;
$$;

-- A member says a section is right (after saving it, or without changing it). Gives its points once a semester.
create or replace function public.profile_confirm(p_section text) returns text
language plpgsql security definer set search_path = public as $$
declare me text := lower(public.jwt_email()); m members; pts int := profile_section_points(p_section); t date := profile_term(); n int;
begin
  if me is null or me = '' then return 'err:signin'; end if;
  if pts = 0 then return 'err:section'; end if;
  select * into m from members where lower(email) = me limit 1;
  if m.email is null then return 'err:member'; end if;
  if not profile_section_filled(m, p_section) then return 'err:empty'; end if;
  insert into profile_checks (email, term, section, points) values (me, t, p_section, pts) on conflict do nothing;
  get diagnostics n = row_count;
  if n = 0 then return 'ok:already'; end if;
  insert into point_awards (email, points, reason, awarded_by)
    values (m.email, pts, 'Profile up to date: ' || profile_section_label(p_section) || ' (' || profile_term_name() || ')', 'system');
  return 'ok';
end $$;
revoke execute on function public.profile_confirm(text) from public, anon;
grant execute on function public.profile_confirm(text) to authenticated;

-- This semester's points for sections that are already filled in. Job preferences are new, so nobody has those yet.
with done as (
  insert into public.profile_checks (email, term, section, points)
  select lower(m.email), public.profile_term(), s.section, public.profile_section_points(s.section)
  from public.members m cross join (values ('year'), ('majors'), ('careers'), ('resume')) s(section)
  where coalesce(m.email, '') <> '' and public.profile_section_filled(m, s.section, false)
  on conflict do nothing
  returning email, section, points
)
insert into public.point_awards (email, points, reason, awarded_by)
select m.email, d.points, 'Profile up to date: ' || public.profile_section_label(d.section) || ' (' || public.profile_term_name() || ')', 'system'
from done d join public.members m on lower(m.email) = d.email;
