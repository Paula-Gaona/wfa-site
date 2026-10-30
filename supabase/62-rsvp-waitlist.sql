-- WFA update: RSVP waitlists. When an event with a seat limit is full, members can join its waitlist. As soon as a
-- seat opens (someone cancels, or an officer raises the seat limit), the first person on the waitlist gets the seat
-- automatically and is notified (by the automatic-emails job, within about 10 minutes). Waitlists stop moving once the
-- event starts. Run once in Supabase -> SQL Editor. Safe to run again.

create table if not exists public.waitlist (
  event_id uuid not null references public.events (id) on delete cascade,
  email text not null default public.jwt_email(),
  created_at timestamptz not null default now(),
  promoted_at timestamptz,      -- when they got a seat (the row stays so they can be notified)
  notified_at timestamptz,      -- when they were told
  primary key (event_id, email)
);
alter table public.waitlist enable row level security;
drop policy if exists "self or officers read waitlist" on public.waitlist;
create policy "self or officers read waitlist" on public.waitlist for select using (email = public.jwt_email() or public.is_officer());
drop policy if exists "members leave the waitlist" on public.waitlist;
create policy "members leave the waitlist" on public.waitlist for delete using (email = public.jwt_email() and promoted_at is null);
grant select, delete on public.waitlist to authenticated;
grant select, insert, update, delete on public.waitlist to service_role;

-- Seats taken: member RSVPs plus guest RSVPs.
create or replace function public.seats_taken(p_event uuid) returns int
language sql stable security definer set search_path = public as $$
  select ((select count(*) from rsvps where event_id = p_event) + (select count(*) from guest_rsvps where event_id = p_event))::int;
$$;

-- Join the waitlist (or just RSVP if a seat is open). Returns 'ok', 'rsvp' (got a seat), or a reason it can't.
create or replace function public.join_waitlist(p_event uuid) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); e events;
begin
  if auth.uid() is null or me is null then return 'signin'; end if;
  select * into e from events where id = p_event for update;
  if e.id is null or e.draft or e.cat in ('officer_meeting', 'case_competition') then return 'missing'; end if;
  if now() >= (e.date + e.start_time) at time zone 'America/Denver' then return 'started'; end if;
  if exists (select 1 from rsvps where event_id = p_event and email = me) then return 'going'; end if;
  if coalesce(e.cap, 0) = 0 or seats_taken(p_event) < e.cap then
    insert into rsvps (event_id, email) values (p_event, me);
    return 'rsvp';
  end if;
  insert into waitlist (event_id, email) values (p_event, me) on conflict (event_id, email) do nothing;
  return 'ok';
end $$;
grant execute on function public.join_waitlist(uuid) to authenticated;

-- Give open seats to the waitlist, first come first served.
create or replace function public.promote_waitlist(p_event uuid) returns int
language plpgsql security definer set search_path = public as $$
declare e events; w record; n int := 0;
begin
  select * into e from events where id = p_event;
  if e.id is null or e.draft or coalesce(e.cap, 0) = 0 then return 0; end if;
  if now() >= (e.date + e.start_time) at time zone 'America/Denver' then return 0; end if;
  for w in select * from waitlist where event_id = p_event and promoted_at is null order by created_at loop
    exit when seats_taken(p_event) >= e.cap;
    if not exists (select 1 from rsvps where event_id = p_event and email = w.email) then
      insert into rsvps (event_id, email) values (p_event, w.email);
      n := n + 1;
    end if;
    update waitlist set promoted_at = now() where event_id = p_event and email = w.email;
  end loop;
  return n;
end $$;
revoke execute on function public.promote_waitlist(uuid) from public, anon, authenticated;

create or replace function public.waitlist_after_cancel() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform promote_waitlist(old.event_id);
  return null;
end $$;
drop trigger if exists waitlist_after_rsvp_cancel on public.rsvps;
create trigger waitlist_after_rsvp_cancel after delete on public.rsvps for each row execute function public.waitlist_after_cancel();
drop trigger if exists waitlist_after_guest_cancel on public.guest_rsvps;
create trigger waitlist_after_guest_cancel after delete on public.guest_rsvps for each row execute function public.waitlist_after_cancel();

create or replace function public.waitlist_after_cap() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.cap is distinct from old.cap or (old.draft and not new.draft) then perform promote_waitlist(new.id); end if;
  return null;
end $$;
drop trigger if exists waitlist_after_cap on public.events;
create trigger waitlist_after_cap after update on public.events for each row execute function public.waitlist_after_cap();

-- RSVPing directly can't jump the line: while anyone is waiting, new RSVPs join the waitlist instead.
create or replace function public.check_capacity() returns trigger
language plpgsql security definer set search_path = public as $$
declare c int;
begin
  select cap into c from events where id = new.event_id;
  if c > 0 and seats_taken(new.event_id) >= c then raise exception 'This event is full.'; end if;
  if c > 0 and exists (select 1 from waitlist w where w.event_id = new.event_id and w.promoted_at is null and w.email <> new.email)
     and not exists (select 1 from waitlist w where w.event_id = new.event_id and w.email = new.email) then
    raise exception 'This event has a waitlist. Join the waitlist instead.';
  end if;
  return new;
end $$;

-- For the site: each event's waitlist size, and where I am on it.
create or replace function public.waitlist_info() returns table (event_id uuid, waiting int, my_place int, promoted boolean)
language sql stable security definer set search_path = public as $$
  with live as (
    select w.* from waitlist w join events e on e.id = w.event_id
    where (e.date + e.end_time) at time zone 'America/Denver' > now()
  ), places as (
    select event_id, email, row_number() over (partition by event_id order by created_at)::int as place
    from live where promoted_at is null
  )
  select l.event_id, (count(*) filter (where l.promoted_at is null))::int,
    (select p.place from places p where p.event_id = l.event_id and p.email = public.jwt_email()),
    coalesce(bool_or(l.email = public.jwt_email() and l.promoted_at is not null), false)
  from live l group by l.event_id;
$$;
grant execute on function public.waitlist_info() to anon, authenticated;
