-- WFA update: more information for choosing case competition teams, and free-agent bios.
--  * Teams answer two questions when they apply (team pitch, required in "officers choose" mode; relevant experience, optional).
--    Captains can edit them until registration closes.
--  * Officers keep a private 1-5 rating and notes on each team (members never see them).
--  * Officers get each member's current-season points to compare teams' involvement.
--  * Free agents write a longer "what I'd bring" bio (up to 600 characters) and check roles they're good at.
-- Run once in Supabase -> SQL Editor, after 37. Safe to run again.

alter table public.case_teams add column if not exists pitch text not null default '';
alter table public.case_teams add column if not exists experience text not null default '';
alter table public.case_teams add column if not exists officer_rating int;
alter table public.case_teams add column if not exists officer_note text not null default '';
alter table public.case_teams drop constraint if exists case_teams_application_check;
alter table public.case_teams add constraint case_teams_application_check check (
  char_length(pitch) <= 800 and char_length(experience) <= 800 and char_length(officer_note) <= 1000
  and (officer_rating is null or officer_rating between 1 and 5));

alter table public.case_free_agents add column if not exists roles text[] not null default '{}';
alter table public.case_free_agents drop constraint if exists case_free_agents_note_check;
alter table public.case_free_agents drop constraint if exists case_free_agents_bio_check;
alter table public.case_free_agents add constraint case_free_agents_bio_check check (char_length(note) <= 600 and cardinality(roles) <= 8);

-- Register a team, now with the application answers.
drop function if exists public.register_team(uuid, text, text[]);
create or replace function public.register_team(p_event uuid, p_name text, p_emails text[], p_pitch text default '', p_experience text default '')
returns text language plpgsql security definer set search_path = public as $$
declare e events; me text := public.jwt_email(); em text; ems text[]; tid uuid;
begin
  if auth.uid() is null then return 'signin'; end if;
  select * into e from events where id = p_event for update;
  if e.id is null or e.cat <> 'case_competition' or e.draft or e.test <> public.is_test() then return 'missing'; end if;
  if now() >= coalesce(e.reg_deadline, (e.date + e.start_time) at time zone 'America/Denver') then return 'closed'; end if;
  if trim(coalesce(p_name, '')) = '' then return 'name'; end if;
  if e.team_mode = 'select' and trim(coalesce(p_pitch, '')) = '' then return 'pitch'; end if;
  if char_length(coalesce(p_pitch, '')) > 800 or char_length(coalesce(p_experience, '')) > 800 then return 'long'; end if;
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
  insert into case_teams (event_id, name, status, pitch, experience)
    values (p_event, left(trim(p_name), 60), case when e.team_mode = 'select' then 'applied' else 'in' end, trim(coalesce(p_pitch, '')), trim(coalesce(p_experience, '')))
    returning id into tid;
  insert into case_team_members (team_id, event_id, email, captain, confirmed) values (tid, p_event, me, true, true);
  insert into case_team_members (team_id, event_id, email) select tid, p_event, x from unnest(ems) x;
  delete from case_free_agents where event_id = p_event and email = me;
  return 'ok';
end $$;
grant execute on function public.register_team(uuid, text, text[], text, text) to authenticated;

-- The captain edits the application answers until registration closes.
create or replace function public.team_update_pitch(p_team uuid, p_pitch text, p_experience text) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); t case_teams; e events;
begin
  select * into t from case_teams where id = p_team;
  if t.id is null then return 'notfound'; end if;
  if not exists (select 1 from case_team_members where team_id = p_team and email = me and captain) then return 'notcaptain'; end if;
  select * into e from events where id = t.event_id;
  if now() >= coalesce(e.reg_deadline, (e.date + e.start_time) at time zone 'America/Denver') then return 'closed'; end if;
  if e.team_mode = 'select' and trim(coalesce(p_pitch, '')) = '' then return 'pitch'; end if;
  if char_length(coalesce(p_pitch, '')) > 800 or char_length(coalesce(p_experience, '')) > 800 then return 'long'; end if;
  update case_teams set pitch = trim(coalesce(p_pitch, '')), experience = trim(coalesce(p_experience, '')) where id = p_team;
  return 'ok';
end $$;
grant execute on function public.team_update_pitch(uuid, text, text) to authenticated;

-- Officers: everyone's points this season, for comparing teams. (Officers already see names and profiles.)
create or replace function public.member_points() returns table (email text, points int, events int)
language plpgsql stable security definer set search_path = public as $$
declare since timestamptz;
begin
  if not (public.is_officer() or public.is_test_admin()) then return; end if;
  select lb_since into since from settings where id = 1;
  return query select s.email, s.points, s.events from lb_standings(since, null) s;
end $$;
grant execute on function public.member_points() to authenticated;

-- The board now includes each team's application answers (for its own members and officers) and free agents'
-- roles, year, and majors. Officer ratings and notes are never included here.
create or replace function public.case_board() returns json
language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then json_build_object('teams', '[]'::json, 'agents', '[]'::json) else json_build_object(
    'teams', coalesce((select json_agg(json_build_object(
        'id', t.id, 'event_id', t.event_id, 'name', t.name, 'status', t.status, 'placement', t.placement, 'created_at', t.created_at,
        'pitch', case when public.can_manage_case(t.event_id) or exists (select 1 from case_team_members x where x.team_id = t.id and x.email = public.jwt_email()) then t.pitch end,
        'experience', case when public.can_manage_case(t.event_id) or exists (select 1 from case_team_members x where x.team_id = t.id and x.email = public.jwt_email()) then t.experience end,
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
        'first', m.first, 'last', m.last, 'note', a.note, 'roles', a.roles, 'year', m.year, 'majors', m.majors) order by a.created_at)
      from case_free_agents a join events e on e.id = a.event_id left join members m on m.email = a.email
      where e.test = public.is_test()), '[]'::json)) end;
$$;
grant execute on function public.case_board() to anon, authenticated;
