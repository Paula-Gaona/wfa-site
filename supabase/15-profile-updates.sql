-- WFA update: year in school, career interests, and leaderboard privacy on member profiles.
-- Run once in Supabase -> SQL Editor. Safe to run again, and safe to run
-- whether or not 14-career-interests.sql was run first.

alter table public.members add column if not exists interests text[] not null default '{}';
alter table public.members add column if not exists year text not null default '';
alter table public.members add column if not exists lb_public boolean not null default true;

-- New accounts: save the year, career interests, and leaderboard choice from the sign-up form.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare m text[]; i text[];
begin
  if jsonb_typeof(new.raw_user_meta_data -> 'majors') = 'array' then
    m := array(select jsonb_array_elements_text(new.raw_user_meta_data -> 'majors'));
  elsif coalesce(new.raw_user_meta_data ->> 'major', '') <> '' then
    m := array[new.raw_user_meta_data ->> 'major'];
  else
    m := '{}';
  end if;
  if jsonb_typeof(new.raw_user_meta_data -> 'interests') = 'array' then
    i := array(select jsonb_array_elements_text(new.raw_user_meta_data -> 'interests'));
  else
    i := '{}';
  end if;
  insert into members (id, email, uvuid, first, last, major, majors, minor, interests, year, lb_public)
  values (new.id, lower(new.email),
          coalesce(new.raw_user_meta_data ->> 'uvuid', ''),
          coalesce(new.raw_user_meta_data ->> 'first', ''),
          coalesce(new.raw_user_meta_data ->> 'last', ''),
          coalesce(m[1], ''), m,
          coalesce(new.raw_user_meta_data ->> 'minor', ''),
          i,
          coalesce(new.raw_user_meta_data ->> 'year', ''),
          coalesce((new.raw_user_meta_data ->> 'lb_public')::boolean, true));
  return new;
end $$;

-- Leaderboard: members who chose to stay anonymous show as "Anonymous Member".
-- Their names never leave the database, except to themselves and to officers.
drop function if exists public.leaderboard();
create function public.leaderboard()
returns table (email text, first text, last text, major text, events int, points int, anon boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  return query
    select case when m.email = jwt_email() then m.email else null end,
      case when m.lb_public or m.email = jwt_email() or is_officer() then m.first else 'Anonymous' end,
      case when m.lb_public or m.email = jwt_email() or is_officer() then m.last else 'Member' end,
      case when m.lb_public or m.email = jwt_email() or is_officer() then array_to_string(m.majors, ' & ') else '' end,
      count(e.id)::int,
      coalesce(sum(event_points(e.cat)), 0)::int,
      not m.lb_public
    from members m
    left join attendance a on a.email = m.email
    left join events e on e.id = a.event_id and e.cat <> 'officer_meeting'
    where not exists (select 1 from access_list al where al.email = m.email)
    group by m.email, m.first, m.last, m.majors, m.lb_public;
end $$;
grant execute on function public.leaderboard() to authenticated;
