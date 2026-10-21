-- WFA update: leaderboard seasons (admins can reset the leaderboard, history is kept)
-- and removing accounting-related content. Run once in Supabase -> SQL Editor. Safe to run again.

-- ---------- Leaderboard seasons ----------
-- The current leaderboard counts check-ins from lb_since onward. Resetting saves the standings as a season, then moves lb_since to now.
alter table public.settings add column if not exists lb_since timestamptz;

create table if not exists public.leaderboard_seasons (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  started_at timestamptz,
  ended_at timestamptz not null default now(),
  created_by text not null default '',
  standings jsonb not null default '[]'::jsonb   -- [{email, first, last, major, events, points, anon}], highest points first
);
alter table public.leaderboard_seasons enable row level security;
-- No direct table access from the site: everything goes through the functions below (which hide anonymous members' names).
grant select, insert, update, delete on public.leaderboard_seasons to service_role;

-- Standings for one time window, with real names. Used inside the other functions only.
create or replace function public.lb_standings(since timestamptz, until timestamptz)
returns table (email text, first text, last text, major text, events int, points int, anon boolean)
language sql stable security definer set search_path = public as $$
  select m.email, m.first, m.last, array_to_string(m.majors, ' & '),
    count(e.id)::int, coalesce(sum(event_points(e.cat)), 0)::int, not m.lb_public
  from members m
  left join attendance a on a.email = m.email
    and (since is null or a.created_at >= since) and (until is null or a.created_at < until)
  left join events e on e.id = a.event_id and e.cat <> 'officer_meeting'
  where not exists (select 1 from access_list al where al.email = m.email)
  group by m.email, m.first, m.last, m.majors, m.lb_public;
$$;
revoke execute on function public.lb_standings(timestamptz, timestamptz) from public, anon, authenticated;

-- The current leaderboard: check-ins since the last reset. Anonymous members show as "Anonymous Member" to other members.
drop function if exists public.leaderboard();
create function public.leaderboard()
returns table (email text, first text, last text, major text, events int, points int, anon boolean)
language plpgsql stable security definer set search_path = public as $$
declare since timestamptz;
begin
  if auth.uid() is null then return; end if;
  select lb_since into since from settings where id = 1;
  return query
    select case when s.email = jwt_email() then s.email else null end,
      case when not s.anon or s.email = jwt_email() or is_officer() then s.first else 'Anonymous' end,
      case when not s.anon or s.email = jwt_email() or is_officer() then s.last else 'Member' end,
      case when not s.anon or s.email = jwt_email() or is_officer() then s.major else '' end,
      s.events, s.points, s.anon
    from lb_standings(since, null) s;
end $$;
grant execute on function public.leaderboard() to authenticated;

-- Admins only: save the current standings as a season and start a fresh leaderboard.
create or replace function public.reset_leaderboard(season_name text)
returns void language plpgsql security definer set search_path = public as $$
declare since timestamptz;
begin
  if not is_admin() then raise exception 'Only admins can reset the leaderboard.'; end if;
  if coalesce(trim(season_name), '') = '' then raise exception 'Give the season a name, like Fall 2026.'; end if;
  select lb_since into since from settings where id = 1;
  insert into leaderboard_seasons (name, started_at, ended_at, created_by, standings)
  values (trim(season_name), since, now(), jwt_email(), coalesce((
    select jsonb_agg(to_jsonb(s) order by s.points desc, s.events desc, s.last)
    from lb_standings(since, now()) s where s.events > 0), '[]'::jsonb));
  update settings set lb_since = now() where id = 1;
end $$;
grant execute on function public.reset_leaderboard(text) to authenticated;

-- Past seasons for members to browse. Anonymous members stay anonymous (by their choice then or now), and emails are only shown to their owner.
create or replace function public.leaderboard_history()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', ls.id, 'name', ls.name, 'started_at', ls.started_at, 'ended_at', ls.ended_at,
      'standings', coalesce((
        select jsonb_agg(jsonb_build_object(
          'me', r->>'email' = jwt_email(),
          'first', case when hide then 'Anonymous' else r->>'first' end,
          'last', case when hide then 'Member' else r->>'last' end,
          'major', case when hide then '' else r->>'major' end,
          'events', (r->>'events')::int, 'points', (r->>'points')::int) order by ord)
        from (select r, ord,
                ((r->>'anon')::boolean or coalesce((select not m.lb_public from members m where m.email = r->>'email'), false))
                  and r->>'email' is distinct from jwt_email() and not is_officer() as hide
              from jsonb_array_elements(ls.standings) with ordinality as x(r, ord)) t), '[]'::jsonb))
      order by ls.ended_at desc)
    from leaderboard_seasons ls), '[]'::jsonb);
end $$;
grant execute on function public.leaderboard_history() to authenticated;

-- Admins can delete a saved season (for mistakes).
create or replace function public.delete_leaderboard_season(season uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Only admins can delete a season.'; end if;
  delete from leaderboard_seasons where id = season;
end $$;
grant execute on function public.delete_leaderboard_season(uuid) to authenticated;

-- ---------- Remove accounting-related content ----------
delete from public.member_resumes where category = 'Controllership & accounting';
update public.members set interests = array_remove(interests, 'Controllership & accounting') where 'Controllership & accounting' = any(interests);
delete from public.careers where title = 'Controllership & accounting';
update public.careers set path = replace(path, 'Learn accounting, valuation (DCF and comparables), and Excel modeling.', 'Learn valuation (DCF and comparables) and Excel modeling.') where title = 'Investment banking';
update public.careers set path = replace(path, 'Strong Excel and accounting skills matter most.', 'Strong Excel and financial modeling skills matter most.') where title like 'FP&A%';
update public.careers set path = replace(path, 'from FP&A and accounting roles', 'from FP&A roles') where title = 'Treasury';
update public.recruiting_timeline set what_text = replace(what_text, 'learn Excel and accounting basics', 'learn Excel and finance basics') where what_text like '%accounting basics%';
