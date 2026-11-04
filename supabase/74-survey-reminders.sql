-- WFA update: scheduled email reminders for surveys from the survey builder. Officers pick up to 5 dates and times per
-- survey. The auto-emails function sends each one to members who haven't answered yet, with the points they can earn.
-- This table records which have gone out, so none is sent twice. Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.surveys add column if not exists remind_at timestamptz[] not null default '{}';

create table if not exists public.survey_reminder_log (
  id uuid primary key default gen_random_uuid(),
  survey_id uuid not null references public.surveys (id) on delete cascade,
  remind_at timestamptz not null,
  recipients int not null default 0,   -- people reached, by email or notification
  emails int not null default 0,       -- emails used from the daily limit
  status text not null default 'sending' check (status in ('sending', 'sent', 'skipped', 'failed')),
  detail text not null default '',
  sent_at timestamptz not null default now(),
  unique (survey_id, remind_at)
);
alter table public.survey_reminder_log enable row level security;
drop policy if exists "officers read survey reminder log" on public.survey_reminder_log;
create policy "officers read survey reminder log" on public.survey_reminder_log for select using (public.is_officer());
grant select on public.survey_reminder_log to authenticated;
grant select, insert, update, delete on public.survey_reminder_log to service_role;
