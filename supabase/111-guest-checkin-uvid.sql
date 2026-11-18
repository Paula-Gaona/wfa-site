-- WFA update: guest check-ins keep the guest's UVU ID when there is one (from their RSVP, or their "I was there" request).
-- Run once in Supabase -> SQL Editor, after 110. Safe to run again.

alter table public.guest_checkins add column if not exists uvid text not null default '';

-- Approving a guest's request adds a guest check-in; a member's, an attendance row.
create or replace function public.review_attendance_claim(p_event uuid, p_email text, p_ok boolean) returns text
language plpgsql security definer set search_path = public as $$
declare c attendance_claims;
begin
  if not public.is_officer() then return 'officers'; end if;
  select * into c from attendance_claims where event_id = p_event and email = p_email;
  if c.email is null then return 'missing'; end if;
  if p_ok then
    if c.guest then
      insert into guest_checkins (event_id, first, last, email, uvid) values (p_event, c.first, c.last, c.email, c.uvid)
      on conflict (event_id, email) do nothing;
    else
      insert into attendance (event_id, email) values (p_event, p_email) on conflict do nothing;
    end if;
    delete from attendance_claims where event_id = p_event and email = p_email;
  else
    update attendance_claims set status = 'denied', reviewed_by = public.jwt_email(), reviewed_at = now()
    where event_id = p_event and email = p_email;
  end if;
  return 'ok';
end $$;
grant execute on function public.review_attendance_claim(uuid, text, boolean) to authenticated;

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
  insert into guest_checkins (event_id, first, last, email, uvid) values (p_event, g.first, g.last, g.email, g.uvid)
  on conflict (event_id, email) do nothing;
  return 'guest';
end $$;
grant execute on function public.uvid_check_in(uuid, text, text) to anon, authenticated;
