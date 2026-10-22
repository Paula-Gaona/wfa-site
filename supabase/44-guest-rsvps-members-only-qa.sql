-- WFA update:
--  1. Members-only events: everyone can see them (so visitors are encouraged to join), but only members can RSVP,
--     check in, or ask questions; there are no guest RSVPs or guest check-ins for them.
--  2. Guest RSVPs: people without an account RSVP with their name and email, and can ask for email reminders about
--     that event. Guest RSVPs count toward seats. If a guest later joins with that email, the RSVP moves to the account.
--     Officers can give members early access: guests can only RSVP after events.guest_rsvp_opens.
--  3. Q&A for guest speakers: officers turn it on per event; members and guests submit questions ahead of time;
--     only officers (and the person who asked) can see them.
-- Run once in Supabase -> SQL Editor, after 43. Safe to run again.

-- ---------- 1. Members-only events ----------
alter table public.events add column if not exists members_only boolean not null default false;

-- ---------- 2. Guest RSVPs ----------
alter table public.events add column if not exists guest_rsvp_opens timestamptz;   -- empty = guests can RSVP right away
create table if not exists public.guest_rsvps (
  event_id uuid not null references public.events (id) on delete cascade,
  first text not null check (char_length(first) between 1 and 60),
  last text not null check (char_length(last) between 1 and 60),
  email text not null check (email = lower(email) and char_length(email) <= 200),
  reminders boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (event_id, email)
);
alter table public.guest_rsvps enable row level security;
drop policy if exists "officers read guest rsvps" on public.guest_rsvps;
create policy "officers read guest rsvps" on public.guest_rsvps for select using (is_officer());
drop policy if exists "officers remove guest rsvps" on public.guest_rsvps;
create policy "officers remove guest rsvps" on public.guest_rsvps for delete using (is_officer());
grant select, delete on public.guest_rsvps to authenticated;
grant select, insert, update, delete on public.guest_rsvps to service_role;

create or replace function public.guest_rsvp(p_event uuid, p_first text, p_last text, p_email text, p_reminders boolean)
returns text language plpgsql security definer set search_path = public as $$
declare e events; em text := lower(trim(coalesce(p_email, '')));
begin
  if trim(coalesce(p_first, '')) = '' or trim(coalesce(p_last, '')) = '' then return 'name'; end if;
  if em !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or char_length(em) > 200 then return 'email'; end if;
  select * into e from events where id = p_event for update;
  if e.id is null or e.draft or e.test or e.members_only or e.cat in ('officer_meeting', 'case_competition') then return 'missing'; end if;
  if now() >= (e.date + e.start_time) at time zone 'America/Denver' then return 'started'; end if;
  if e.guest_rsvp_opens is not null and now() < e.guest_rsvp_opens then return 'notyet'; end if;
  if exists (select 1 from members m where m.email = em) then return 'member'; end if;
  if exists (select 1 from guest_rsvps g where g.event_id = p_event and g.email = em) then
    update guest_rsvps set reminders = coalesce(p_reminders, false) where event_id = p_event and email = em;
    return 'ok';
  end if;
  if e.cap > 0 and (select count(*) from rsvps where event_id = p_event) + (select count(*) from guest_rsvps where event_id = p_event) >= e.cap then return 'full'; end if;
  insert into guest_rsvps (event_id, first, last, email, reminders)
    values (p_event, left(trim(p_first), 60), left(trim(p_last), 60), em, coalesce(p_reminders, false));
  return 'ok';
end $$;
grant execute on function public.guest_rsvp(uuid, text, text, text, boolean) to anon, authenticated;

-- Seats: guest RSVPs count too.
create or replace function public.check_capacity() returns trigger
language plpgsql security definer set search_path = public as $$
declare c int;
begin
  select cap into c from events where id = new.event_id;
  if c > 0 and (select count(*) from rsvps where event_id = new.event_id)
             + (select count(*) from guest_rsvps where event_id = new.event_id) >= c then
    raise exception 'This event is full.';
  end if;
  return new;
end $$;

-- RSVP counts on the site include guests.
create or replace function public.event_stats()
returns table (event_id uuid, rsvps int, attended int)
language sql stable security definer set search_path = public as $$
  select e.id,
    ((select count(*) from rsvps r where r.event_id = e.id) + (select count(*) from guest_rsvps g where g.event_id = e.id))::int,
    (select count(*) from attendance a where a.event_id = e.id)::int
  from events e
  where (e.cat <> 'officer_meeting' or is_officer() or is_test_admin()) and e.test = is_test()
$$;

-- Guest check-in isn't allowed for members-only events.
create or replace function public.guest_check_in(p_event uuid, p_code text, p_first text, p_last text, p_email text)
returns text language plpgsql security definer set search_path = public as $$
declare d date; st time; c text; t boolean; dr boolean; mo boolean; cat text; em text := lower(trim(coalesce(p_email, '')));
begin
  if trim(coalesce(p_first, '')) = '' or trim(coalesce(p_last, '')) = '' then return 'name'; end if;
  if em !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or char_length(em) > 200 then return 'email'; end if;
  select e."date", e.start_time, e.test, e.draft, e.members_only, e.cat into d, st, t, dr, mo, cat from events e where e.id = p_event;
  if d is null or t or dr or mo or cat = 'officer_meeting' then return 'missing'; end if;
  if d <> (now() at time zone 'America/Denver')::date then return 'closed'; end if;
  if now() < (d + st) at time zone 'America/Denver' - interval '15 minutes' then return 'early'; end if;
  select code into c from checkin_codes where event_id = p_event;
  if c is null then return 'notstarted'; end if;
  if upper(trim(coalesce(p_code, ''))) <> c then return 'wrong'; end if;
  if exists (select 1 from members m where m.email = em) then return 'member'; end if;
  insert into guest_checkins (event_id, first, last, email)
  values (p_event, left(trim(p_first), 60), left(trim(p_last), 60), em)
  on conflict (event_id, email) do nothing;
  return 'ok';
end $$;

-- When someone joins with an email they used as a guest: their guest check-ins and guest RSVPs move to the account.
create or replace function public.claim_guest_checkins() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into attendance (event_id, email)
    select g.event_id, new.email from guest_checkins g where g.email = lower(new.email)
  on conflict do nothing;
  delete from guest_checkins where email = lower(new.email);
  with moved as (delete from guest_rsvps where email = lower(new.email) returning event_id)
  insert into rsvps (event_id, email) select event_id, new.email from moved on conflict do nothing;
  return new;
end $$;

-- ---------- 3. Q&A for guest speakers ----------
alter table public.events add column if not exists qa_enabled boolean not null default false;
create table if not exists public.event_questions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  email text,                                   -- empty for guests who didn't give one
  name text not null default '',
  question text not null check (char_length(trim(question)) between 1 and 600),
  starred boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.event_questions enable row level security;
drop policy if exists "officers and askers read questions" on public.event_questions;
create policy "officers and askers read questions" on public.event_questions for select
  using (is_officer() or (email is not null and email = jwt_email()));
drop policy if exists "officers star questions" on public.event_questions;
create policy "officers star questions" on public.event_questions for update using (is_officer()) with check (is_officer());
drop policy if exists "officers and askers delete questions" on public.event_questions;
create policy "officers and askers delete questions" on public.event_questions for delete
  using (is_officer() or (email is not null and email = jwt_email()));
grant select, update, delete on public.event_questions to authenticated;
grant select, insert, update, delete on public.event_questions to service_role;

-- Ask a question (members are identified by their account; guests give a name).
create or replace function public.ask_question(p_event uuid, p_question text, p_name text default '') returns text
language plpgsql security definer set search_path = public as $$
declare e events; me text := public.jwt_email(); nm text;
begin
  select * into e from events where id = p_event;
  if e.id is null or not e.qa_enabled or e.draft or e.test <> public.is_test() or (e.members_only and auth.uid() is null) then return 'missing'; end if;
  if now() >= (e.date + e.end_time) at time zone 'America/Denver' then return 'closed'; end if;
  if trim(coalesce(p_question, '')) = '' then return 'empty'; end if;
  if char_length(p_question) > 600 then return 'long'; end if;
  if me is not null then select trim(m.first || ' ' || m.last) into nm from members m where m.email = me; end if;
  if coalesce(nm, '') = '' then nm := left(trim(coalesce(p_name, '')), 80); end if;
  if nm = '' then return 'name'; end if;
  if (select count(*) from event_questions q where q.event_id = p_event and q.created_at > now() - interval '1 hour'
        and ((me is not null and q.email = me) or (me is null and q.email is null and q.name = nm))) >= 5 then return 'many'; end if;
  insert into event_questions (event_id, email, name, question) values (p_event, me, nm, trim(p_question));
  return 'ok';
end $$;
grant execute on function public.ask_question(uuid, text, text) to anon, authenticated;
