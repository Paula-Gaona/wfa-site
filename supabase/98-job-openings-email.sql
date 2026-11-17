-- WFA update: the "Job openings" email. Each listing remembers when it was first emailed, so the next Job openings
-- email only includes listings that haven't gone out yet. It goes out automatically every Monday at 9 AM Mountain
-- Time (Admin -> Automatic emails), and officers can also send one from the email builder anytime.
-- Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.job_postings add column if not exists mailed_at timestamptz;

-- One row per Monday, claimed before sending so it only goes out once.
create table if not exists public.job_digest_log (
  week text primary key,              -- the Monday, like 2026-11-23
  recipients int not null default 0,
  emails int not null default 0,
  jobs int not null default 0,        -- listings included
  status text not null default 'sending' check (status in ('sending', 'sent', 'skipped', 'failed')),
  detail text not null default '',
  sent_at timestamptz not null default now()
);
alter table public.job_digest_log enable row level security;
drop policy if exists "admins read job digest log" on public.job_digest_log;
create policy "admins read job digest log" on public.job_digest_log for select using (is_admin());
grant select on public.job_digest_log to authenticated;
grant select, insert, update on public.job_digest_log to service_role;
