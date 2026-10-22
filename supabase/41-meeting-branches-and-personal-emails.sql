-- WFA update:
--  1. Officer meetings say which branches and positions are required or invited (none set = all officers).
--  2. Automatic emails now go one per person, greeting each by first name, so the daily safety limit counts
--     people instead of BCC batches. This raises the default and any saved limit to 500.
-- Run once in Supabase -> SQL Editor, after 40. Safe to run again.

-- meeting_who looks like {"operations": "required", "president": "invited"}. Keys: the three branches and the
-- positions president, vice_president, officer (regular officers), advisor. Anything left out isn't included.
alter table public.events add column if not exists meeting_who jsonb not null default '{}'::jsonb;
create or replace function public.valid_meeting_who(j jsonb) returns boolean language sql immutable as $$
  select jsonb_typeof(j) = 'object' and not exists (select 1 from jsonb_each_text(j) x
    where x.key not in ('communications', 'operations', 'financial_applications', 'president', 'vice_president', 'officer', 'advisor')
       or x.value not in ('required', 'invited'));
$$;
alter table public.events drop constraint if exists events_meeting_who_check;
alter table public.events add constraint events_meeting_who_check check (public.valid_meeting_who(meeting_who));

alter table public.settings alter column auto_email set default
  '{"enabled": false, "reminders": [{"key": "7d", "on": false, "to": "all"}, {"key": "1d", "on": true, "to": "rsvp"}, {"key": "2h", "on": true, "to": "rsvp"}], "survey": true, "daily_cap": 500}'::jsonb;
update public.settings set auto_email = jsonb_set(auto_email, '{daily_cap}', '500'::jsonb)
  where id = 1 and coalesce((auto_email ->> 'daily_cap')::int, 0) < 500;
