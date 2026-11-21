-- WFA update: members can volunteer for event roles.
-- An officer opens spots on a role to volunteers. Members who qualify sign up on the event page, get the same
-- day-before instructions officers do, and earn bonus points once an officer confirms they did the job.
--   Who can volunteer: members (not officers) who have attended at least one event, with no no-shows this semester.
--   Bonus: 25 points for a role that arrives 30 minutes or more early, 15 for any other.
--   Cancelling 48 hours or more before the event: no penalty. Inside 48 hours: no volunteering for the rest of the
--   semester. Not cancelling and not coming: no volunteering for a year. An officer can lift a block.
-- A volunteer is added to the role's "officers" list (with their email also in "vols"), so the role emails and the
-- automatic RSVP treat them like anyone else on the role.
-- Run once in Supabase -> SQL Editor, after 100. Safe to run again.

create table if not exists public.volunteer_log (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  email text not null,
  role text not null,
  bonus int not null default 15,
  status text not null default 'signed' check (status in ('signed', 'cancelled', 'late_cancel', 'done', 'no_show')),
  forgiven boolean not null default false,     -- an officer lifted the block this row causes
  told boolean not null default false,         -- the officer in charge was told about the cancellation
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by text not null default '',
  unique (event_id, email)
);
alter table public.volunteer_log enable row level security;
drop policy if exists "officers and the volunteer read volunteer log" on public.volunteer_log;
create policy "officers and the volunteer read volunteer log" on public.volunteer_log for select using (is_officer() or lower(email) = lower(jwt_email()));
grant select on public.volunteer_log to authenticated;
grant select, insert, update, delete on public.volunteer_log to service_role;

-- The semester's first day, going by today's date (Mountain Time): January 1, May 1, or August 1.
create or replace function public.term_start() returns date
language sql stable as $$
  select make_date(extract(year from d)::int, case when extract(month from d) >= 8 then 8 when extract(month from d) >= 5 then 5 else 1 end, 1)
  from (select (now() at time zone 'America/Denver')::date as d) x;
$$;

-- Why someone can't volunteer right now, or null if they can.
create or replace function public.volunteer_block(p_email text) returns text
language plpgsql stable security definer set search_path = public as $$
declare me text := lower(p_email); today date := (now() at time zone 'America/Denver')::date;
begin
  if not exists (select 1 from members m where lower(m.email) = me) then return 'err:member'; end if;
  if exists (select 1 from volunteer_log v join events e on e.id = v.event_id
             where lower(v.email) = me and v.status = 'no_show' and not v.forgiven and e.date > today - 365) then return 'err:year'; end if;
  if exists (select 1 from volunteer_log v join events e on e.id = v.event_id
             where lower(v.email) = me and v.status = 'late_cancel' and not v.forgiven and e.date >= term_start()) then return 'err:term'; end if;
  if not exists (select 1 from attendance a where lower(a.email) = me) then return 'err:first'; end if;
  -- A no-show: RSVP'd to an event this semester that's over, where people checked in and they didn't.
  if exists (select 1 from rsvps r join events e on e.id = r.event_id
             where lower(r.email) = me and not coalesce(r.by_role, false) and not e.draft and e.cat <> 'officer_meeting'
               and e.date >= term_start() and e.date < today
               and exists (select 1 from attendance a where a.event_id = e.id)
               and not exists (select 1 from attendance a where a.event_id = e.id and lower(a.email) = me)) then return 'err:noshow'; end if;
  return null;
end $$;
revoke execute on function public.volunteer_block(text) from public, anon, authenticated;

-- The bonus for a role: 25 for arriving 30 minutes or more early, 15 otherwise (including cleanup afterward).
create or replace function public.volunteer_bonus(r jsonb) returns int
language sql immutable as $$
  select case when coalesce(r->>'phase', '') <> 'after' and coalesce((r->>'arrive')::numeric, 0) >= 30 then 25 else 15 end;
$$;

-- What a signed-in member sees: whether they can volunteer, the open spots on upcoming events, and their own sign-ups.
create or replace function public.volunteer_board() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me text := lower(public.jwt_email()); spots jsonb; mine jsonb;
begin
  if me is null or me = '' then return null; end if;
  select coalesce(jsonb_object_agg(x.event_id, x.list), '{}'::jsonb) into spots from (
    select er.event_id, jsonb_agg(jsonb_build_object('role', r->>'name', 'phase', r->>'phase', 'arrive', coalesce((r->>'arrive')::numeric, 0),
        'duties', coalesce(r->>'duties', ''), 'bonus', volunteer_bonus(r),
        'left', least(coalesce((r->>'open')::int, 0) - jsonb_array_length(coalesce(r->'vols', '[]'::jsonb)),
                      coalesce((r->>'qty')::int, 1) - jsonb_array_length(coalesce(r->'officers', '[]'::jsonb)))) order by ord) as list
    from event_roles er join events e on e.id = er.event_id
      cross join lateral jsonb_array_elements(er.roles) with ordinality t(r, ord)
    where not e.draft and now() < (e.date + e.start_time) at time zone 'America/Denver' and coalesce((r->>'open')::int, 0) > 0
    group by er.event_id) x;
  select coalesce(jsonb_agg(jsonb_build_object('event_id', v.event_id, 'role', v.role, 'bonus', v.bonus, 'status', v.status)), '[]'::jsonb) into mine
    from volunteer_log v where lower(v.email) = me;
  return jsonb_build_object('block', case when public.is_officer() then 'err:officer' else volunteer_block(me) end, 'events', spots, 'mine', mine);
end $$;
grant execute on function public.volunteer_board() to authenticated;

-- Take a volunteer spot.
create or replace function public.volunteer_signup(p_event uuid, p_role text) returns text
language plpgsql security definer set search_path = public as $$
declare me text := lower(public.jwt_email()); e events; er event_roles; r jsonb; why text; b int;
begin
  if me is null or me = '' then return 'err:signin'; end if;
  if public.is_officer() then return 'err:officer'; end if;
  why := volunteer_block(me); if why is not null then return why; end if;
  select * into e from events where id = p_event;
  if e.id is null or e.draft then return 'err:missing'; end if;
  if now() >= (e.date + e.start_time) at time zone 'America/Denver' then return 'err:started'; end if;
  if exists (select 1 from volunteer_log v where v.event_id = p_event and lower(v.email) = me and v.status = 'signed') then return 'err:already'; end if;
  select * into er from event_roles where event_id = p_event for update;
  select x into r from jsonb_array_elements(coalesce(er.roles, '[]'::jsonb)) x where x->>'name' = p_role limit 1;
  if r is null or coalesce((r->>'open')::int, 0) <= 0 then return 'err:closed'; end if;
  if jsonb_array_length(coalesce(r->'vols', '[]'::jsonb)) >= (r->>'open')::int
     or jsonb_array_length(coalesce(r->'officers', '[]'::jsonb)) >= coalesce((r->>'qty')::int, 1) then return 'err:full'; end if;
  b := volunteer_bonus(r);
  update event_roles set updated_at = now(), updated_by = me, roles = (
    select jsonb_agg(case when x->>'name' = p_role
        then jsonb_set(jsonb_set(x, '{officers}', coalesce(x->'officers', '[]'::jsonb) || to_jsonb(me)), '{vols}', coalesce(x->'vols', '[]'::jsonb) || to_jsonb(me))
        else x end order by ord)
    from jsonb_array_elements(roles) with ordinality t(x, ord)) where event_id = p_event;
  insert into volunteer_log (event_id, email, role, bonus, status, updated_by) values (p_event, me, p_role, b, 'signed', me)
    on conflict (event_id, email) do update set role = excluded.role, bonus = excluded.bonus, status = 'signed', forgiven = false, told = false, updated_at = now(), updated_by = me;
  perform sync_role_rsvps(p_event);
  return 'ok';
end $$;
grant execute on function public.volunteer_signup(uuid, text) to authenticated;

-- Take someone off every role's volunteer list for an event.
create or replace function public.volunteer_remove(p_event uuid, p_email text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update event_roles set updated_at = now(), roles = (
    select coalesce(jsonb_agg(case when coalesce(x->'vols', '[]'::jsonb) ? p_email
        then jsonb_set(jsonb_set(x, '{officers}', (select coalesce(jsonb_agg(o), '[]'::jsonb) from jsonb_array_elements(coalesce(x->'officers', '[]'::jsonb)) o where o <> to_jsonb(p_email))),
                       '{vols}', (select coalesce(jsonb_agg(o), '[]'::jsonb) from jsonb_array_elements(x->'vols') o where o <> to_jsonb(p_email)))
        else x end order by ord), '[]'::jsonb)
    from jsonb_array_elements(roles) with ordinality t(x, ord)) where event_id = p_event;
  perform sync_role_rsvps(p_event);
end $$;
revoke execute on function public.volunteer_remove(uuid, text) from public, anon, authenticated;

-- Give a spot back. 48 hours or more before the start: no penalty. Later than that: blocked for the semester.
create or replace function public.volunteer_cancel(p_event uuid) returns text
language plpgsql security definer set search_path = public as $$
declare me text := lower(public.jwt_email()); e events; late boolean;
begin
  select * into e from events where id = p_event;
  if e.id is null then return 'err:missing'; end if;
  if not exists (select 1 from volunteer_log v where v.event_id = p_event and lower(v.email) = me and v.status = 'signed') then return 'err:notsigned'; end if;
  if now() >= (e.date + e.start_time) at time zone 'America/Denver' then return 'err:started'; end if;
  late := now() > ((e.date + e.start_time) at time zone 'America/Denver') - interval '48 hours';
  perform volunteer_remove(p_event, me);
  update volunteer_log set status = case when late then 'late_cancel' else 'cancelled' end, told = false, updated_at = now(), updated_by = me
    where event_id = p_event and lower(email) = me;
  return case when late then 'ok:late' else 'ok' end;
end $$;
grant execute on function public.volunteer_cancel(uuid) to authenticated;

-- Officers: after the event starts, say whether a volunteer did the job. Yes adds the bonus points; no blocks them for a year.
-- Changing the answer later undoes the earlier one.
create or replace function public.volunteer_mark(p_event uuid, p_email text, p_did boolean) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); v volunteer_log; e events; why text;
begin
  if not public.is_officer() then return 'err:notofficer'; end if;
  select * into v from volunteer_log where event_id = p_event and lower(email) = lower(p_email);
  if v.id is null or v.status not in ('signed', 'done', 'no_show') then return 'err:notsigned'; end if;
  select * into e from events where id = p_event;
  if now() < (e.date + e.start_time) at time zone 'America/Denver' then return 'err:early'; end if;
  why := left('Volunteered (' || v.role || ') at ' || e.title, 200);
  delete from point_awards where lower(email) = lower(v.email) and reason = why and rule_id is null;
  if p_did then insert into point_awards (email, points, reason, awarded_by) values (v.email, v.bonus, why, me); end if;
  update volunteer_log set status = case when p_did then 'done' else 'no_show' end, forgiven = false, updated_at = now(), updated_by = me where id = v.id;
  return 'ok';
end $$;
grant execute on function public.volunteer_mark(uuid, text, boolean) to authenticated;

-- Officers: lift the block a late cancellation or a no-show caused.
create or replace function public.volunteer_forgive(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_officer() then return 'err:notofficer'; end if;
  update volunteer_log set forgiven = true, updated_at = now(), updated_by = public.jwt_email() where id = p_id and status in ('late_cancel', 'no_show');
  return 'ok';
end $$;
grant execute on function public.volunteer_forgive(uuid) to authenticated;
