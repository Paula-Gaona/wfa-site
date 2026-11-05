-- WFA update: the Jobs page. Officers list internships, full-time jobs, and employers who recruit year-round (a link to
-- their careers page instead of a posting), one at a time or from an Excel file. Anyone can read them.
-- Run once in Supabase -> SQL Editor. Safe to run again.

create table if not exists public.job_postings (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  created_by text not null default public.jwt_email(),
  kind text not null check (kind in ('internship', 'full_time', 'employer')),
  company text not null check (char_length(company) between 1 and 120),
  title text not null default '' check (char_length(title) <= 200),   -- blank for an employer
  descr text not null default '' check (char_length(descr) <= 5000),
  url text not null check (url ~* '^https?://'),
  opens_on date,
  closes_on date,
  careers text[] not null default '{}',     -- ids from public.careers
  semesters text[] not null default '{}',   -- 'Fall 2026'
  officer_notes text not null default '' check (char_length(officer_notes) <= 2000),
  check (kind = 'employer' or title <> '')
);
alter table public.job_postings enable row level security;
drop policy if exists "anyone reads job postings" on public.job_postings;
create policy "anyone reads job postings" on public.job_postings for select using (true);
drop policy if exists "officers write job postings" on public.job_postings;
create policy "officers write job postings" on public.job_postings for all using (public.is_officer()) with check (public.is_officer());
grant select on public.job_postings to anon, authenticated;
grant insert, update, delete on public.job_postings to authenticated;
grant select, insert, update, delete on public.job_postings to service_role;
