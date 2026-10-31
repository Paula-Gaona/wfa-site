-- WFA update: the Semester plan lists each planned event on its own ("Guest speaker #1", "Guest speaker #2", "Panel")
-- with a description, and contacts are attached to the specific planned event they're filling or being considered for.
-- The counts from before are turned into that many planned events. Leadership (presidents, vice presidents, the faculty
-- advisor, and admins) adds, removes, and describes them; every officer can see them.
-- Run once in Supabase -> SQL Editor, after 68-contacts.sql. Safe to run again.

create table if not exists public.planned_events (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  created_by text not null default coalesce(public.jwt_email(), ''),
  semester text not null check (char_length(semester) between 1 and 40),
  cat text not null check (char_length(cat) between 1 and 40),     -- an event type, or 'panel'
  sort int not null default 0,
  descr text not null default '' check (char_length(descr) <= 2000)
);
alter table public.planned_events enable row level security;
drop policy if exists "officers read planned events" on public.planned_events;
create policy "officers read planned events" on public.planned_events for select using (public.is_officer());
drop policy if exists "leadership writes planned events" on public.planned_events;
create policy "leadership writes planned events" on public.planned_events for all
  using (public.is_admin() or exists (select 1 from public.officer_profiles o where o.email = public.jwt_email() and o.tier in ('president', 'vice_president', 'advisor')))
  with check (public.is_admin() or exists (select 1 from public.officer_profiles o where o.email = public.jwt_email() and o.tier in ('president', 'vice_president', 'advisor')));
grant select, insert, update, delete on public.planned_events to authenticated;
grant select, insert, update, delete on public.planned_events to service_role;

-- The planned event a contact is filling or being considered for.
alter table public.contacts add column if not exists plan_id uuid references public.planned_events (id) on delete set null;

-- Turn the old counts into planned events (only for kinds that don't have any yet).
insert into public.planned_events (semester, cat, sort, created_by)
select p.semester, p.cat, g, 'plan counts'
from public.outreach_plan p, generate_series(1, p.target) g
where p.target > 0 and not exists (select 1 from public.planned_events e where e.semester = p.semester and e.cat = p.cat);

-- Contacts already confirmed for a kind of event fill the first open planned event of that kind.
do $$
declare c record; pe uuid;
begin
  for c in select * from public.contacts where plan_id is null and status in ('confirmed', 'done') and confirmed_cat <> '' order by updated_at loop
    select e.id into pe from public.planned_events e
      where e.semester = c.semester and e.cat = c.confirmed_cat
        and not exists (select 1 from public.contacts x where x.plan_id = e.id and x.status in ('confirmed', 'done'))
      order by e.sort, e.created_at limit 1;
    if pe is not null then update public.contacts set plan_id = pe where id = c.id; end if;
  end loop;
end $$;
