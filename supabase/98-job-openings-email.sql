-- WFA update: the "Job openings" email (email builder layout). Each listing remembers when it was first emailed, so
-- the next Job openings email only includes listings that haven't gone out yet.
-- Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.job_postings add column if not exists mailed_at timestamptz;
