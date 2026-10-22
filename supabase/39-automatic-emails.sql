-- WFA update: automatic emails (event reminders and post-event survey emails).
-- Admins turn them on and choose them in Admin -> Automatic emails. Every 10 minutes Supabase runs the
-- "auto-emails" Edge Function (supabase/auto-emails.ts), which sends whatever is due and records it here
-- so nothing is ever sent twice. Club emails skip members who turned them off, test accounts, and test events.
-- Before running this: deploy the auto-emails Edge Function (see the steps in auto-emails.ts).
-- Run once in Supabase -> SQL Editor, after 38. Safe to run again.

-- Settings. Off until an admin turns them on.
alter table public.settings add column if not exists auto_email jsonb not null default
  '{"enabled": false, "reminders": [{"key": "7d", "on": false, "to": "all"}, {"key": "1d", "on": true, "to": "rsvp"}, {"key": "2h", "on": true, "to": "rsvp"}], "survey": true, "daily_cap": 60}'::jsonb;

-- What was sent (one row per event and kind, so nothing goes out twice).
create table if not exists public.auto_email_log (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  kind text not null,                -- remind_7d, remind_1d, remind_2h, survey
  recipients int not null default 0,
  emails int not null default 0,     -- emails used from the daily limit (recipients go in BCC, 45 per email)
  status text not null default 'sending' check (status in ('sending', 'sent', 'skipped', 'failed')),
  detail text not null default '',
  sent_at timestamptz not null default now(),
  unique (event_id, kind)
);
alter table public.auto_email_log enable row level security;
drop policy if exists "admins read auto email log" on public.auto_email_log;
create policy "admins read auto email log" on public.auto_email_log for select using (is_admin());
-- Explicit grants (required for new tables from Oct 30, 2026). Only the Edge Function (service role) writes here.
grant select on public.auto_email_log to authenticated;
grant select, insert, update, delete on public.auto_email_log to service_role;

-- Run the Edge Function every 10 minutes.
create extension if not exists pg_cron;
create extension if not exists pg_net;
select cron.unschedule(jobid) from cron.job where jobname = 'wfa-auto-emails';
select cron.schedule('wfa-auto-emails', '*/10 * * * *', $job$
  select net.http_post(
    url := 'https://razxymbbfsnnnguyaalp.supabase.co/functions/v1/auto-emails',
    -- The site's public (publishable) key, the same one in site/index.html. Supabase requires it on function calls.
    headers := '{"Content-Type": "application/json", "apikey": "sb_publishable_G9Ct3sh1zfK2peRadj-nzg_SSLCr2Sn"}'::jsonb,
    body := '{}'::jsonb);
$job$);
