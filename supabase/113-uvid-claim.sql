-- WFA update: "I was there" without signing in. UVU ID + last name + one thing you learned.
-- Matches a WFA account first (points once approved); otherwise a guest who gave that UVU ID when they RSVP'd.
-- Run once in Supabase -> SQL Editor, after 112. Safe to run again.

create or replace function public.uvid_claim_attendance(p_event uuid, p_uvid text, p_last text, p_note text) returns text
language plpgsql security definer set search_path = public as $$
declare e events; ends timestamptz; em text; g guest_rsvps;
  u text := regexp_replace(coalesce(p_uvid, ''), '\D', '', 'g');
  l text := lower(trim(coalesce(p_last, '')));
begin
  if u !~ '^\d{8}$' then return 'uvid'; end if;
  if l = '' then return 'last'; end if;
  if char_length(trim(coalesce(p_note, ''))) < 20 then return 'note'; end if;
  select * into e from events where id = p_event;
  if e.id is null or e.draft or e.test or e.cat = 'officer_meeting'
     or coalesce(e.host, '') <> '' or e.reg_mode = 'link' then return 'missing'; end if;
  ends := (e.date + e.end_time) at time zone 'America/Denver';
  if now() < ends then return 'notover'; end if;
  if now() > ends + interval '7 days' then return 'late'; end if;
  select m.email into em from members m
    where (m.uvuid = u or lower(m.email) = u || '@uvu.edu') and lower(trim(m.last)) = l
    order by (m.uvuid = u) desc limit 1;
  if em is not null then
    if exists (select 1 from attendance where event_id = p_event and email = em) then return 'here'; end if;
    insert into attendance_claims (event_id, email, note) values (p_event, em, left(trim(p_note), 300))
    on conflict (event_id, email) do nothing;
    return 'ok';
  end if;
  if e.members_only then return 'nomatch'; end if;
  select * into g from guest_rsvps where uvid = u and lower(trim(last)) = l
    order by (event_id = p_event) desc, created_at desc limit 1;
  if g.email is null then return 'nomatch'; end if;
  if exists (select 1 from guest_checkins where event_id = p_event and email = g.email) then return 'here'; end if;
  insert into attendance_claims (event_id, email, note, guest, first, last, uvid)
  values (p_event, g.email, left(trim(p_note), 300), true, g.first, g.last, u)
  on conflict (event_id, email) do nothing;
  return 'guest';
end $$;
grant execute on function public.uvid_claim_attendance(uuid, text, text, text) to anon, authenticated;
