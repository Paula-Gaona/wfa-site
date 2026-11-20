-- WFA update: checklist reminders.
-- The officer who owns a planning-checklist task gets a reminder the day before it's due (auto-emails.ts sends it,
-- from 9 AM Mountain Time). reminded_at records that the reminder went out, so it's only sent once; the site clears
-- it when the due date changes, so a rescheduled task is reminded again.
-- Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.tasks add column if not exists reminded_at timestamptz;
