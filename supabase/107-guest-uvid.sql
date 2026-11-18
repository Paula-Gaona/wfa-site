-- WFA update: guests can give their UVU ID when they RSVP (optional), and then check in with just their UVU ID and
-- the code, like members. Guest RSVPs now also use the same seat count as member RSVPs (officers with roles left out
-- unless the event counts them).
-- Run once in Supabase -> SQL Editor, after 106. Safe to run again.

alter table public.guest_rsvps add column if not exists uvid text not null default '';
alter table public.guest_rsvps drop constraint if exists guest_rsvps_uvid_check;
alter table public.guest_rsvps add constraint guest_rsvps_uvid_check check (uvid = '' or uvid ~ '^\d{8}$');

drop function if exists public.guest_rsvp(uuid, text, text, text, boolean);
create or replace function public.guest_rsvp(p_event uuid, p_first text, p_last text, p_email text, p_reminders boolean, p_uvid text default '')
returns text language plpgsql security definer set search_path = public as $$
declare e events; em text := lower(trim(coalesce(p_email, '')));
  u text := regexp_replace(coalesce(p_uvid, ''), '\D', '', 'g');
begin
  if trim(coalesce(p_first, '')) = '' or trim(coalesce(p_last, '')) = '' then return 'name'; end if;
  if em !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or char_length(em) > 200 then return 'email'; end if;
  if u <> '' and u !~ '^\d{8}$' then return 'uvid'; end if;
  select * into e from events where id = p_event for update;
  if e.id is null or e.draft or e.test or e.members_only or e.cat in ('officer_meeting', 'case_competition') then return 'missing'; end if;
  if now() >= (e.date + e.start_time) at time zone 'America/Denver' then return 'started'; end if;
  if e.guest_rsvp_opens is not null and now() < e.guest_rsvp_opens then return 'notyet'; end if;
  if exists (select 1 from members m where m.email = em) then return 'member'; end if;
  if u <> '' and exists (select 1 from members m where m.uvuid = u) then return 'memberid'; end if;
  if exists (select 1 from guest_rsvps g where g.event_id = p_event and g.email = em) then
    update guest_rsvps set reminders = coalesce(p_reminders, false), uvid = case when u <> '' then u else uvid end
      where event_id = p_event and email = em;
    return 'ok';
  end if;
  if e.cap > 0 and seats_taken(p_event) >= e.cap then return 'full'; end if;
  insert into guest_rsvps (event_id, first, last, email, reminders, uvid)
    values (p_event, left(trim(p_first), 60), left(trim(p_last), 60), em, coalesce(p_reminders, false), u);
  return 'ok';
end $$;
grant execute on function public.guest_rsvp(uuid, text, text, text, boolean, text) to anon, authenticated;

-- Check in with a UVU ID: members first; otherwise a guest who gave that UVU ID on an RSVP is checked in as a guest.
-- Returns 'ok' (member), 'guest', or why not.
create or replace function public.uvid_check_in(p_event uuid, p_code text, p_uvid text) returns text
language plpgsql security definer set search_path = public as $$
declare d date; st time; et time; op timestamptz; c text; t boolean; dr boolean; mo boolean; cat text; em text; g guest_rsvps;
  u text := regexp_replace(coalesce(p_uvid, ''), '\D', '', 'g');
begin
  if u !~ '^\d{8}$' then return 'uvid'; end if;
  select e."date", e.start_time, e.end_time, e.checkin_opened_at, e.test, e.draft, e.members_only, e.cat
    into d, st, et, op, t, dr, mo, cat from events e where e.id = p_event;
  if d is null or t or dr then return 'missing'; end if;
  if not public.checkin_is_open(d, st, et, op) then
    if d <> (now() at time zone 'America/Denver')::date then return 'closed'; end if;
    return 'early';
  end if;
  select code into c from checkin_codes where event_id = p_event;
  if c is null then return 'notstarted'; end if;
  if upper(trim(coalesce(p_code, ''))) <> c then return 'wrong'; end if;
  select m.email into em from members m where m.uvuid = u or lower(m.email) = u || '@uvu.edu'
    order by (m.uvuid = u) desc limit 1;
  if em is not null then
    insert into attendance (event_id, email) values (p_event, em) on conflict do nothing;
    return 'ok';
  end if;
  if mo or cat = 'officer_meeting' then return 'nomember'; end if;
  select * into g from guest_rsvps where uvid = u order by (event_id = p_event) desc, created_at desc limit 1;
  if g.email is null then return 'nomember'; end if;
  insert into guest_checkins (event_id, first, last, email) values (p_event, g.first, g.last, g.email)
  on conflict (event_id, email) do nothing;
  return 'guest';
end $$;
grant execute on function public.uvid_check_in(uuid, text, text) to anon, authenticated;
