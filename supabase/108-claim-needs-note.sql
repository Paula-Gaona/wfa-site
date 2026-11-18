-- WFA update: "I was there" requests need one thing the member learned or heard at the event (at least 20 characters).
-- Run once in Supabase -> SQL Editor, after 107. Safe to run again.

-- A member asks to be added. Returns 'ok' or why not.
create or replace function public.claim_attendance(p_event uuid, p_note text) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); e events; ends timestamptz;
begin
  if auth.uid() is null or me is null then return 'signin'; end if;
  select * into e from events where id = p_event;
  if e.id is null or e.draft or e.test <> public.is_test() or e.cat = 'officer_meeting'
     or coalesce(e.host, '') <> '' or e.reg_mode = 'link' then return 'missing'; end if;
  ends := (e.date + e.end_time) at time zone 'America/Denver';
  if now() < ends then return 'notover'; end if;
  if now() > ends + interval '7 days' then return 'late'; end if;
  if exists (select 1 from attendance where event_id = p_event and email = me) then return 'here'; end if;
  if char_length(trim(coalesce(p_note, ''))) < 20 then return 'note'; end if;
  insert into attendance_claims (event_id, email, note) values (p_event, me, left(trim(coalesce(p_note, '')), 300))
  on conflict (event_id, email) do nothing;
  return 'ok';
end $$;
grant execute on function public.claim_attendance(uuid, text) to authenticated;
