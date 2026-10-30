-- WFA update: a reminder to update your profile (year, majors, career interests, resume) at the start of each
-- semester: January, May, and August (on the 8th at 10 AM Mountain Time, or the first run after). Each one goes out
-- once; this table records which have been sent. Admins can turn it off in Admin -> Automatic emails.
-- Run once in Supabase -> SQL Editor. Safe to run again.

create table if not exists public.profile_reminders (
  period text primary key,                     -- '2027-01'
  sent_at timestamptz not null default now(),
  sent int not null default 0
);
alter table public.profile_reminders enable row level security;
drop policy if exists "admins read profile reminders" on public.profile_reminders;
create policy "admins read profile reminders" on public.profile_reminders for select using (public.is_admin());
grant select on public.profile_reminders to authenticated;
grant select, insert, update, delete on public.profile_reminders to service_role;
