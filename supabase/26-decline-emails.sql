-- WFA update: decline emails for officer applications.
-- Tracks when each declined applicant was emailed, and saves the admins' wording for next time.
-- Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.applications add column if not exists decline_emailed_at timestamptz;
alter table public.app_settings add column if not exists decline_template jsonb not null default '{}'::jsonb;
