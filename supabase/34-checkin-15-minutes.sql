-- WFA update: check-in opens 15 minutes before an event starts (Mountain Time), not at midnight.
-- Run once in Supabase -> SQL Editor, after 33. Safe to run again.

create or replace function public.check_in(p_event uuid, p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare d date; st time; c text; t boolean;
begin
  if auth.uid() is null then return 'signin'; end if;
  select e."date", e.start_time, e.test into d, st, t from events e where e.id = p_event;
  if d is null or t <> public.is_test() then return 'missing'; end if;
  if d <> (now() at time zone 'America/Denver')::date then return 'closed'; end if;
  if now() < (d + st) at time zone 'America/Denver' - interval '15 minutes' then return 'early'; end if;
  select code into c from checkin_codes where event_id = p_event;
  if c is null then return 'notstarted'; end if;
  if upper(trim(p_code)) <> c then return 'wrong'; end if;
  insert into attendance (event_id, email) values (p_event, jwt_email()) on conflict do nothing;
  return 'ok';
end $$;
