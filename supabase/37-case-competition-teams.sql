-- WFA update: team registration for case competitions.
-- Officers set team size (min-max), an optional team limit, a registration deadline, and a mode:
--   fcfs   = first come, first served: teams are in as they register until the limit fills, then registration closes
--   select = any number of teams apply; officers accept teams (up to the limit) or decline them
-- A captain registers a team and invites teammates by email. Every teammate needs an account and confirms with one
-- click. Students without a team can join a free-agent list. After the event, officers mark 1st/2nd/3rd place, which
-- gives each confirmed teammate bonus leaderboard points (50 / 30 / 15).
-- Run once in Supabase -> SQL Editor, after 36. Safe to run again.

-- ---------- Event settings ----------
alter table public.events add column if not exists team_min int not null default 2;
alter table public.events add column if not exists team_max int not null default 4;
alter table public.events add column if not exists team_limit int;
alter table public.events add column if not exists team_mode text not null default 'fcfs';
alter table public.events add column if not exists reg_deadline timestamptz;
alter table public.events drop constraint if exists events_team_settings_check;
alter table public.events add constraint events_team_settings_check check (
  team_min between 1 and 20 and team_max between 1 and 20 and team_max >= team_min
  and (team_limit is null or team_limit between 1 and 500) and team_mode in ('fcfs', 'select'));

-- ---------- Teams, teammates, free agents ----------
create table if not exists public.case_teams (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  name text not null check (char_length(trim(name)) between 1 and 60),
  status text not null default 'in' check (status in ('in', 'applied', 'declined')),
  placement int check (placement between 1 and 3),
  placed_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index if not exists case_teams_name_unique on public.case_teams (event_id, lower(name));

create table if not exists public.case_team_members (
  team_id uuid not null references public.case_teams (id) on delete cascade,
  event_id uuid not null references public.events (id) on delete cascade,
  email text not null check (email = lower(email)),
  captain boolean not null default false,
  confirmed boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (team_id, email),
  unique (event_id, email)                       -- one team per person per competition
);

create table if not exists public.case_free_agents (
  event_id uuid not null references public.events (id) on delete cascade,
  email text not null default public.jwt_email(),
  note text not null default '' check (char_length(note) <= 300),
  created_at timestamptz not null default now(),
  primary key (event_id, email)
);

alter table public.case_teams enable row level security;
alter table public.case_team_members enable row level security;
alter table public.case_free_agents enable row level security;

-- Members change teams only through the functions below. Officers (and the test admin, for test events) manage them directly.
create or replace function public.can_manage_case(ev uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_officer() and exists (select 1 from events e where e.id = ev and not e.test)
      or public.is_test_admin() and exists (select 1 from events e where e.id = ev and e.test);
$$;
grant execute on function public.can_manage_case(uuid) to authenticated;

drop policy if exists "officers read teams" on public.case_teams;
create policy "officers read teams" on public.case_teams for select using (can_manage_case(event_id));
drop policy if exists "officers update teams" on public.case_teams;
create policy "officers update teams" on public.case_teams for update using (can_manage_case(event_id)) with check (can_manage_case(event_id));
drop policy if exists "officers delete teams" on public.case_teams;
create policy "officers delete teams" on public.case_teams for delete using (can_manage_case(event_id));
drop policy if exists "officers read teammates" on public.case_team_members;
create policy "officers read teammates" on public.case_team_members for select using (can_manage_case(event_id));
drop policy if exists "officers remove teammates" on public.case_team_members;
create policy "officers remove teammates" on public.case_team_members for delete using (can_manage_case(event_id));

-- Free agents: add or remove yourself while registration is open; officers can remove anyone.
create or replace function public.case_reg_open(ev uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from events e where e.id = ev and e.cat = 'case_competition' and not e.draft and e.test = public.is_test()
    and now() < coalesce(e.reg_deadline, (e.date + e.start_time) at time zone 'America/Denver'));
$$;
grant execute on function public.case_reg_open(uuid) to authenticated;
drop policy if exists "members list themselves as free agents" on public.case_free_agents;
create policy "members list themselves as free agents" on public.case_free_agents for insert with check (
  auth.uid() is not null and email = jwt_email() and case_reg_open(event_id)
  and not exists (select 1 from case_team_members m where m.event_id = case_free_agents.event_id and m.email = jwt_email()));
drop policy if exists "free agents remove themselves" on public.case_free_agents;
create policy "free agents remove themselves" on public.case_free_agents for delete using (email = jwt_email() or can_manage_case(event_id));
drop policy if exists "officers read free agents" on public.case_free_agents;
create policy "officers read free agents" on public.case_free_agents for select using (email = jwt_email() or can_manage_case(event_id));

-- Explicit grants (required for new tables from Oct 30, 2026). The policies above still decide access.
grant select, update, delete on public.case_teams to authenticated;
grant select, delete on public.case_team_members to authenticated;
grant select, insert, delete on public.case_free_agents to authenticated;
grant select, insert, update, delete on public.case_teams, public.case_team_members, public.case_free_agents to service_role;

-- Officers accepting a team can't go past the team limit. Placements record when they were set (for leaderboard seasons).
create or replace function public.guard_case_team() returns trigger
language plpgsql security definer set search_path = public as $$
declare lim int;
begin
  if new.status = 'in' and old.status <> 'in' then
    select team_limit into lim from events where id = new.event_id;
    if lim is not null and (select count(*) from case_teams where event_id = new.event_id and status = 'in') >= lim then
      raise exception 'The team limit (%) is full. Decline or remove a team first.', lim;
    end if;
  end if;
  if new.placement is distinct from old.placement then new.placed_at := case when new.placement is null then null else now() end; end if;
  return new;
end $$;
drop trigger if exists case_teams_guard on public.case_teams;
create trigger case_teams_guard before update on public.case_teams for each row execute function public.guard_case_team();

-- ---------- What members can do ----------
-- Register a team. Returns 'ok' or a short reason the site turns into a message.
create or replace function public.register_team(p_event uuid, p_name text, p_emails text[]) returns text
language plpgsql security definer set search_path = public as $$
declare e events; me text := public.jwt_email(); em text; ems text[]; tid uuid;
begin
  if auth.uid() is null then return 'signin'; end if;
  select * into e from events where id = p_event for update;     -- one registration at a time per event, so the limit can't be overrun
  if e.id is null or e.cat <> 'case_competition' or e.draft or e.test <> public.is_test() then return 'missing'; end if;
  if now() >= coalesce(e.reg_deadline, (e.date + e.start_time) at time zone 'America/Denver') then return 'closed'; end if;
  if trim(coalesce(p_name, '')) = '' then return 'name'; end if;
  if exists (select 1 from case_team_members where event_id = p_event and email = me) then return 'already'; end if;
  select coalesce(array_agg(distinct x), '{}') into ems
    from (select lower(trim(u)) as x from unnest(coalesce(p_emails, '{}'::text[])) u) s where x <> '' and x <> me;
  foreach em in array ems loop
    if em !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then return 'email:' || em; end if;
  end loop;
  if 1 + cardinality(ems) > e.team_max then return 'toobig'; end if;
  select string_agg(email, ', ') into em from case_team_members where event_id = p_event and email = any(ems);
  if em is not null then return 'taken:' || em; end if;
  if exists (select 1 from case_teams where event_id = p_event and lower(name) = lower(trim(p_name))) then return 'dupname'; end if;
  if e.team_mode = 'fcfs' and e.team_limit is not null
     and (select count(*) from case_teams where event_id = p_event and status = 'in') >= e.team_limit then return 'full'; end if;
  insert into case_teams (event_id, name, status)
    values (p_event, left(trim(p_name), 60), case when e.team_mode = 'select' then 'applied' else 'in' end) returning id into tid;
  insert into case_team_members (team_id, event_id, email, captain, confirmed) values (tid, p_event, me, true, true);
  insert into case_team_members (team_id, event_id, email) select tid, p_event, x from unnest(ems) x;
  delete from case_free_agents where event_id = p_event and email = me;
  return 'ok';
end $$;

-- An invited teammate joins (confirms) or declines.
create or replace function public.team_respond(p_team uuid, p_accept boolean) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); ev uuid;
begin
  select event_id into ev from case_team_members where team_id = p_team and email = me;
  if ev is null then return 'notfound'; end if;
  if p_accept then
    update case_team_members set confirmed = true where team_id = p_team and email = me;
    delete from case_free_agents where event_id = ev and email = me;
  else
    delete from case_team_members where team_id = p_team and email = me and not captain;
  end if;
  return 'ok';
end $$;

-- The captain invites another teammate (by email) while registration is open and the team has room.
create or replace function public.team_add(p_team uuid, p_email text) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); em text := lower(trim(coalesce(p_email, ''))); t case_teams; e events;
begin
  select * into t from case_teams where id = p_team;
  if t.id is null then return 'notfound'; end if;
  if not exists (select 1 from case_team_members where team_id = p_team and email = me and captain) then return 'notcaptain'; end if;
  select * into e from events where id = t.event_id;
  if now() >= coalesce(e.reg_deadline, (e.date + e.start_time) at time zone 'America/Denver') then return 'closed'; end if;
  if em !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then return 'email:' || em; end if;
  if (select count(*) from case_team_members where team_id = p_team) >= e.team_max then return 'toobig'; end if;
  if exists (select 1 from case_team_members where event_id = t.event_id and email = em) then return 'taken:' || em; end if;
  insert into case_team_members (team_id, event_id, email) values (p_team, t.event_id, em);
  return 'ok';
end $$;

-- Remove someone from a team: the captain removes a teammate, anyone can leave, and a captain leaving withdraws the team.
create or replace function public.team_remove(p_team uuid, p_email text) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); em text := lower(trim(coalesce(p_email, ''))); is_cap boolean;
begin
  select captain into is_cap from case_team_members where team_id = p_team and email = me;
  if is_cap is null then return 'notfound'; end if;
  if em = me and is_cap then delete from case_teams where id = p_team; return 'withdrawn'; end if;
  if em <> me and not is_cap then return 'notcaptain'; end if;
  delete from case_team_members where team_id = p_team and email = em and not captain;
  return 'ok';
end $$;

grant execute on function public.register_team(uuid, text, text[]) to authenticated;
grant execute on function public.team_respond(uuid, boolean) to authenticated;
grant execute on function public.team_add(uuid, text) to authenticated;
grant execute on function public.team_remove(uuid, text) to authenticated;

-- ---------- What the site shows ----------
-- Teams and free agents for every case competition the viewer can see. Members see accepted teams (plus their own),
-- teammates' emails only on their own team, and free agents' names, emails, and notes (free agents agree to that).
create or replace function public.case_board() returns json
language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then json_build_object('teams', '[]'::json, 'agents', '[]'::json) else json_build_object(
    'teams', coalesce((select json_agg(json_build_object(
        'id', t.id, 'event_id', t.event_id, 'name', t.name, 'status', t.status, 'placement', t.placement, 'created_at', t.created_at,
        'members', (select json_agg(json_build_object(
            'email', case when public.can_manage_case(t.event_id)
                            or exists (select 1 from case_team_members x where x.team_id = t.id and x.email = public.jwt_email())
                          then cm.email end,
            'me', cm.email = public.jwt_email(), 'first', m.first, 'last', m.last,
            'joined', m.email is not null, 'captain', cm.captain, 'confirmed', cm.confirmed) order by cm.captain desc, cm.created_at)
          from case_team_members cm left join members m on m.email = cm.email where cm.team_id = t.id)
      ) order by t.created_at)
      from case_teams t join events e on e.id = t.event_id
      where e.test = public.is_test() and (not e.draft or public.can_manage_case(e.id))
        and (t.status = 'in' or public.can_manage_case(e.id)
             or exists (select 1 from case_team_members x where x.team_id = t.id and x.email = public.jwt_email()))), '[]'::json),
    'agents', coalesce((select json_agg(json_build_object('event_id', a.event_id, 'email', a.email, 'me', a.email = public.jwt_email(),
        'first', m.first, 'last', m.last, 'note', a.note) order by a.created_at)
      from case_free_agents a join events e on e.id = a.event_id left join members m on m.email = a.email
      where e.test = public.is_test()), '[]'::json)) end;
$$;
grant execute on function public.case_board() to anon, authenticated;

-- ---------- Leaderboard: placement bonus points ----------
create or replace function public.placement_points(p int) returns int language sql immutable as $$
  select case p when 1 then 50 when 2 then 30 when 3 then 15 else 0 end;
$$;
create or replace function public.lb_standings(since timestamptz, until timestamptz)
returns table (email text, first text, last text, major text, events int, points int, anon boolean)
language sql stable security definer set search_path = public as $$
  select m.email, m.first, m.last, array_to_string(m.majors, ' & '),
    coalesce(att.n, 0)::int,
    (coalesce(att.p, 0) + coalesce(aw.p, 0) + 2 * coalesce(sv.n, 0) + coalesce(pl.p, 0))::int,
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
