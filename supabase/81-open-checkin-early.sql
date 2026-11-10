-- WFA update: admins can open check-in early ("Open check-in now" on the event page). Normally check-in opens 15
-- minutes before an event starts, on the day of the event. Once an admin opens it, members and guests can check in
-- right away, until the event ends. An admin can close it again, which goes back to the usual 15-minute rule.
-- Run once in Supabase -> SQL Editor, after 44. Safe to run again.

alter table public.events add column if not exists checkin_opened_at timestamptz;

-- Admins only: open check-in now (p_open = true) or undo it (false).
create or replace function public.open_checkin(p_event uuid, p_open boolean) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then return 'denied'; end if;
  update events set checkin_opened_at = case when p_open then now() else null end where id = p_event;
  if not found then return 'missing'; end if;
  return 'ok';
end $$;
grant execute on function public.open_checkin(uuid, boolean) to authenticated;

-- Whether check-in is open for an event right now: the usual 15 minutes before the start on the day of the event,
-- or from when an admin opened it early until the event ends.
create or replace function public.checkin_is_open(d date, st time, et time, opened timestamptz) returns boolean
language sql stable as $$
  select (d = (now() at time zone 'America/Denver')::date and now() >= (d + st) at time zone 'America/Denver' - interval '15 minutes')
      or (opened is not null and now() >= opened and now() < (d + et) at time zone 'America/Denver')
$$;

-- Same as 34-checkin-15-minutes.sql, with the early opening.
create or replace function public.check_in(p_event uuid, p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare d date; st time; et time; op timestamptz; c text; t boolean;
begin
  if auth.uid() is null then return 'signin'; end if;
  select e."date", e.start_time, e.end_time, e.checkin_opened_at, e.test into d, st, et, op, t from events e where e.id = p_event;
  if d is null or t <> public.is_test() then return 'missing'; end if;
  if not public.checkin_is_open(d, st, et, op) then
    if d <> (now() at time zone 'America/Denver')::date then return 'closed'; end if;
    return 'early';
  end if;
  select code into c from checkin_codes where event_id = p_event;
  if c is null then return 'notstarted'; end if;
  if upper(trim(p_code)) <> c then return 'wrong'; end if;
  insert into attendance (event_id, email) values (p_event, jwt_email()) on conflict do nothing;
  return 'ok';
end $$;

-- Same as 44-guest-rsvps-members-only-qa.sql, with the early opening.
create or replace function public.guest_check_in(p_event uuid, p_code text, p_first text, p_last text, p_email text)
returns text language plpgsql security definer set search_path = public as $$
declare d date; st time; et time; op timestamptz; c text; t boolean; dr boolean; mo boolean; cat text; em text := lower(trim(coalesce(p_email, '')));
begin
  if trim(coalesce(p_first, '')) = '' or trim(coalesce(p_last, '')) = '' then return 'name'; end if;
  if em !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or char_length(em) > 200 then return 'email'; end if;
  select e."date", e.start_time, e.end_time, e.checkin_opened_at, e.test, e.draft, e.members_only, e.cat
    into d, st, et, op, t, dr, mo, cat from events e where e.id = p_event;
  if d is null or t or dr or mo or cat = 'officer_meeting' then return 'missing'; end if;
  if not public.checkin_is_open(d, st, et, op) then
    if d <> (now() at time zone 'America/Denver')::date then return 'closed'; end if;
    return 'early';
  end if;
  select code into c from checkin_codes where event_id = p_event;
  if c is null then return 'notstarted'; end if;
  if upper(trim(coalesce(p_code, ''))) <> c then return 'wrong'; end if;
  if exists (select 1 from members m where m.email = em) then return 'member'; end if;
  insert into guest_checkins (event_id, first, last, email)
  values (p_event, left(trim(p_first), 60), left(trim(p_last), 60), em)
  on conflict (event_id, email) do nothing;
  return 'ok';
end $$;
