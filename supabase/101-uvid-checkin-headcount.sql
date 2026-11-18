-- WFA update:
-- 1. Members can check in without signing in: their UVU ID and the code on screen. It finds their account by the UVU ID
--    on their profile (or a 12345678@uvu.edu email) and checks them in with the usual points.
-- 2. Officers can add a headcount for people who came but aren't on any list (no names, no points), so an event's
--    attendance can match the room.
-- Run once in Supabase -> SQL Editor, after 100. Safe to run again.

create or replace function public.uvid_check_in(p_event uuid, p_code text, p_uvid text) returns text
language plpgsql security definer set search_path = public as $$
declare d date; st time; et time; op timestamptz; c text; t boolean; dr boolean; em text;
  u text := regexp_replace(coalesce(p_uvid, ''), '\D', '', 'g');
begin
  if u !~ '^\d{8}$' then return 'uvid'; end if;
  select e."date", e.start_time, e.end_time, e.checkin_opened_at, e.test, e.draft into d, st, et, op, t, dr from events e where e.id = p_event;
  if d is null or t or dr then return 'missing'; end if;
  if not public.checkin_is_open(d, st, et, op) then
    if d <> (now() at time zone 'America/Denver')::date then return 'closed'; end if;
    return 'early';
  end if;
  select code into c from checkin_codes where event_id = p_event;
  if c is null then return 'notstarted'; end if;
  if upper(trim(coalesce(p_code, ''))) <> c then return 'wrong'; end if;
  select m.email into em from members m where m.uvuid = u or lower(m.email) = u || '@uvu.edu'
    order by (m.uvuid = u) desc limit 1;
  if em is null then return 'nomember'; end if;
  insert into attendance (event_id, email) values (p_event, em) on conflict do nothing;
  return 'ok';
end $$;
grant execute on function public.uvid_check_in(uuid, text, text) to anon, authenticated;

create table if not exists public.event_headcount (
  event_id uuid primary key references public.events(id) on delete cascade,
  extra int not null default 0 check (extra between 0 and 2000),
  updated_by text not null default '',
  updated_at timestamptz not null default now()
);
alter table public.event_headcount enable row level security;
drop policy if exists "officers read headcount" on public.event_headcount;
create policy "officers read headcount" on public.event_headcount for select using (is_officer());
drop policy if exists "officers add headcount" on public.event_headcount;
create policy "officers add headcount" on public.event_headcount for insert with check (is_officer());
drop policy if exists "officers edit headcount" on public.event_headcount;
create policy "officers edit headcount" on public.event_headcount for update using (is_officer()) with check (is_officer());
grant select, insert, update on public.event_headcount to authenticated;
