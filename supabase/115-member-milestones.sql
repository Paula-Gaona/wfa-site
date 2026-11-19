-- WFA update: officers get a notice every time membership passes another 50 members (100, 150, 200, ...).
-- This table records which milestones were already announced, so each goes out once. The milestone the club has
-- already passed today is marked as announced, so the first notice is for the next one.
-- Run once in Supabase -> SQL Editor, after 114. Safe to run again. Then update the auto-emails function.

create table if not exists public.member_milestones (
  count int primary key,                       -- 100, 150, 200, ...
  reached_at timestamptz not null default now()
);
alter table public.member_milestones enable row level security;
drop policy if exists "officers read member milestones" on public.member_milestones;
create policy "officers read member milestones" on public.member_milestones for select using (public.is_officer());
grant select on public.member_milestones to authenticated;
grant select, insert, update, delete on public.member_milestones to service_role;

insert into public.member_milestones (count)
select (count(*) / 50) * 50 from public.members m
where not exists (select 1 from public.test_accounts t where t.email = m.email)
having count(*) >= 50
on conflict do nothing;
