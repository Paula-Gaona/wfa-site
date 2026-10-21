-- WFA update: guest check-in.
-- People without an account can check in to an event with their name, email, and the code on screen, under the
-- same rules as members (day of the event, from 15 minutes before it starts). Guests don't earn points. If a guest
-- later joins with the same email, their guest check-ins move to their account and count for points.
-- Run once in Supabase -> SQL Editor, after 34. Safe to run again.

create table if not exists public.guest_checkins (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  first text not null check (char_length(first) between 1 and 60),
  last text not null check (char_length(last) between 1 and 60),
  email text not null check (email = lower(email) and char_length(email) <= 200),
  created_at timestamptz not null default now(),
  unique (event_id, email)
);
alter table public.guest_checkins enable row level security;
-- Officers see and remove guest check-ins. Guests add theirs only through guest_check_in() below.
drop policy if exists "officers read guests" on public.guest_checkins;
create policy "officers read guests" on public.guest_checkins for select using (is_officer());
drop policy if exists "officers remove guests" on public.guest_checkins;
create policy "officers remove guests" on public.guest_checkins for delete using (is_officer());
-- Explicit grants (required for new tables from Oct 30, 2026). The policies above still decide access.
grant select, delete on public.guest_checkins to authenticated;
grant select, insert, update, delete on public.guest_checkins to service_role;

create or replace function public.guest_check_in(p_event uuid, p_code text, p_first text, p_last text, p_email text)
returns text language plpgsql security definer set search_path = public as $$
declare d date; st time; c text; t boolean; dr boolean; cat text; em text := lower(trim(coalesce(p_email, '')));
begin
  if trim(coalesce(p_first, '')) = '' or trim(coalesce(p_last, '')) = '' then return 'name'; end if;
  if em !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or char_length(em) > 200 then return 'email'; end if;
  select e."date", e.start_time, e.test, e.draft, e.cat into d, st, t, dr, cat from events e where e.id = p_event;
  if d is null or t or dr or cat = 'officer_meeting' then return 'missing'; end if;
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
grant execute on function public.guest_check_in(uuid, text, text, text, text) to anon, authenticated;

-- When someone joins with an email they used as a guest, those check-ins become real check-ins (with points).
create or replace function public.claim_guest_checkins() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into attendance (event_id, email)
    select g.event_id, new.email from guest_checkins g where g.email = lower(new.email)
  on conflict do nothing;
  delete from guest_checkins where email = lower(new.email);
  return new;
end $$;
drop trigger if exists members_claim_guest_checkins on public.members;
create trigger members_claim_guest_checkins after insert on public.members
  for each row execute function public.claim_guest_checkins();
