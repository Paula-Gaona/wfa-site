-- WFA update: check-in closes 30 minutes after an event ends (it used to stay open the rest of the day). After that,
-- members who forgot use "I was there" on the event page, which an officer approves.
-- Run once in Supabase -> SQL Editor, after 108. Safe to run again.
create or replace function public.checkin_is_open(d date, st time, et time, opened timestamptz) returns boolean
language sql stable as $$
  select now() < (d + et) at time zone 'America/Denver' + interval '30 minutes'
     and ((d = (now() at time zone 'America/Denver')::date and now() >= (d + st) at time zone 'America/Denver' - interval '15 minutes')
          or (opened is not null and now() >= opened))
$$;
