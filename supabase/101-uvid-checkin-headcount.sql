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

-- 3. Members can RSVP without signing in: their UVU ID and last name (both must match their profile). Same rules as
--    RSVPing on the site: when RSVPs open and close, the seat limit, and the waitlist when it's full.
create or replace function public.uvid_rsvp(p_event uuid, p_uvid text, p_last text) returns text
language plpgsql security definer set search_path = public as $$
declare e events; em text;
  u text := regexp_replace(coalesce(p_uvid, ''), '\D', '', 'g');
  l text := lower(trim(coalesce(p_last, '')));
begin
  if u !~ '^\d{8}$' then return 'uvid'; end if;
  if l = '' then return 'last'; end if;
  select * into e from events where id = p_event for update;
  if e.id is null or e.draft or e.test or e.reg_mode <> 'rsvp' or e.cat in ('officer_meeting', 'case_competition') then return 'missing'; end if;
  if now() >= (e.date + e.start_time) at time zone 'America/Denver' then return 'started'; end if;
  if e.rsvp_opens is not null and now() < e.rsvp_opens then return 'notyet'; end if;
  if e.rsvp_closes is not null and now() >= e.rsvp_closes then return 'closed'; end if;
  select m.email into em from members m
    where (m.uvuid = u or lower(m.email) = u || '@uvu.edu') and lower(trim(m.last)) = l
    order by (m.uvuid = u) desc limit 1;
  if em is null then return 'nomember'; end if;
  if exists (select 1 from rsvps where event_id = p_event and email = em) then return 'going'; end if;
  if coalesce(e.cap, 0) = 0 or (seats_taken(p_event) < e.cap
       and not exists (select 1 from waitlist w where w.event_id = p_event and w.promoted_at is null and w.email <> em)) then
    insert into rsvps (event_id, email) values (p_event, em);
    return 'rsvp';
  end if;
  insert into waitlist (event_id, email) values (p_event, em) on conflict (event_id, email) do nothing;
  return 'waitlist';
end $$;
grant execute on function public.uvid_rsvp(uuid, text, text) to anon, authenticated;
