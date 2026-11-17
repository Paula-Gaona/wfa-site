-- WFA update: members choose which job openings the newsletter shows them first: big-name firms (Wall Street,
-- Fortune 500, and other top firms on the notable firms list), Utah, or both (the default, same as before).
-- Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.members add column if not exists job_focus text not null default 'both';
alter table public.members drop constraint if exists members_job_focus_check;
alter table public.members add constraint members_job_focus_check check (job_focus in ('both', 'big', 'utah'));
