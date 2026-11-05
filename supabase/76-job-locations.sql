-- WFA update: job listings can be tagged remote and with one or more states, for the Location filter on the Jobs page.
-- Run once in Supabase -> SQL Editor, after 75-job-postings.sql. Safe to run again.
alter table public.job_postings add column if not exists states text[] not null default '{}';   -- 'UT', 'NY'
alter table public.job_postings add column if not exists remote boolean not null default false;
