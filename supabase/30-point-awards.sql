-- WFA update: admins can award (or remove) leaderboard points, to one member or many at once.
-- Awards count toward the current season like check-ins do, and are saved with past seasons on reset.
-- Run once in Supabase -> SQL Editor, after 28-leaderboard-seasons.sql. Safe to run again.

create table if not exists public.point_awards (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  email text not null,
  points int not null check (points between -1000 and 1000 and points <> 0),
  reason text not null check (char_length(reason) between 1 and 200),
  awarded_by text not null default public.jwt_email()
);
alter table public.point_awards enable row level security;
drop policy if exists "admins read awards" on public.point_awards;
create policy "admins read awards" on public.point_awards for select using (is_admin() or email = jwt_email());
drop policy if exists "admins give awards" on public.point_awards;
create policy "admins give awards" on public.point_awards for insert with check (is_admin() and awarded_by = jwt_email());
drop policy if exists "admins remove awards" on public.point_awards;
create policy "admins remove awards" on public.point_awards for delete using (is_admin());
-- Explicit grants (Supabase stops granting new tables automatically on Oct 30, 2026). RLS above still decides who can do what.
grant select, insert, delete on public.point_awards to authenticated;
grant select, insert, update, delete on public.point_awards to service_role;

-- Standings now add awarded points to check-in points.
create or replace function public.lb_standings(since timestamptz, until timestamptz)
returns table (email text, first text, last text, major text, events int, points int, anon boolean)
language sql stable security definer set search_path = public as $$
  select m.email, m.first, m.last, array_to_string(m.majors, ' & '),
    coalesce(att.n, 0)::int,
    (coalesce(att.p, 0) + coalesce(aw.p, 0))::int,
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
  where not exists (select 1 from access_list al where al.email = m.email);
$$;
revoke execute on function public.lb_standings(timestamptz, timestamptz) from public, anon, authenticated;

-- Resetting keeps anyone with points, including people who only have awarded points.
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
    from lb_standings(since, now()) s where s.events > 0 or s.points <> 0), '[]'::jsonb));
  update settings set lb_since = now() where id = 1;
end $$;
grant execute on function public.reset_leaderboard(text) to authenticated;
