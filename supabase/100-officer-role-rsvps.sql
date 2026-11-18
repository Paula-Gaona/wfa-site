-- WFA update: officers with a role at an event are RSVP'd to it automatically, so the RSVP total (what food is
-- ordered from) includes them. Each event's roles have a switch for whether those officers take seats from the seat
-- limit. Off (the default): they never take a member's seat or push anyone onto the waitlist. On: they count like
-- everyone else (but still always get in, even if the event is full).
-- Taking someone off their role removes the RSVP that came from it. RSVPs officers made themselves are never touched.
-- Run once in Supabase -> SQL Editor, after 99. Safe to run again.

alter table public.rsvps add column if not exists by_role boolean not null default false;      -- added because of a role
alter table public.event_roles add column if not exists count_seats boolean not null default false;

-- The officers on an event's roles (lowercase emails).
create or replace function public.role_officers(p_event uuid) returns setof text
language sql stable security definer set search_path = public as $$
  select distinct lower(o)
  from event_roles er
  cross join lateral jsonb_array_elements(case when jsonb_typeof(er.roles) = 'array' then er.roles else '[]'::jsonb end) r
  cross join lateral jsonb_array_elements_text(case when jsonb_typeof(r->'officers') = 'array' then r->'officers' else '[]'::jsonb end) o
  where er.event_id = p_event and trim(o) <> '';
$$;
revoke execute on function public.role_officers(uuid) from public, anon, authenticated;

-- Seats taken: member RSVPs plus guest RSVPs, leaving out officers with roles unless the event counts them.
create or replace function public.seats_taken(p_event uuid) returns int
language sql stable security definer set search_path = public as $$
  select ((select count(*) from rsvps r where r.event_id = p_event
             and (coalesce((select count_seats from event_roles where event_id = p_event), false)
                  or lower(r.email) not in (select o from role_officers(p_event) o)))
        + (select count(*) from guest_rsvps where event_id = p_event))::int;
$$;

-- Full events and waitlists don't apply to officers with roles: they always get in.
create or replace function public.check_capacity() returns trigger
language plpgsql security definer set search_path = public as $$
declare c int;
begin
  if lower(coalesce(new.email, '')) in (select o from role_officers(new.event_id) o) then return new; end if;
  select cap into c from events where id = new.event_id;
  if c > 0 and seats_taken(new.event_id) >= c then raise exception 'This event is full.'; end if;
  if c > 0 and exists (select 1 from waitlist w where w.event_id = new.event_id and w.promoted_at is null and w.email <> new.email)
     and not exists (select 1 from waitlist w where w.event_id = new.event_id and w.email = new.email) then
    raise exception 'This event has a waitlist. Join the waitlist instead.';
  end if;
  return new;
end $$;

-- RSVP the officers on an event's roles, and remove role RSVPs for officers taken off them. Only for published
-- "RSVP on this site" events that haven't started.
create or replace function public.sync_role_rsvps(p_event uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e events;
begin
  select * into e from events where id = p_event;
  if e.id is null or e.draft or e.reg_mode <> 'rsvp' or e.cat in ('officer_meeting', 'case_competition') then return; end if;
  if now() >= (e.date + e.start_time) at time zone 'America/Denver' then return; end if;
  insert into rsvps (event_id, email, by_role)
    select p_event, o, true from role_officers(p_event) o
    where not exists (select 1 from rsvps r where r.event_id = p_event and lower(r.email) = o)
    on conflict do nothing;
  delete from rsvps r where r.event_id = p_event and r.by_role and lower(r.email) not in (select o from role_officers(p_event) o);
  delete from waitlist w where w.event_id = p_event and w.promoted_at is null and lower(w.email) in (select o from role_officers(p_event) o);
  perform promote_waitlist(p_event);   -- seats may have opened (officers stopped counting, or someone was taken off)
end $$;
revoke execute on function public.sync_role_rsvps(uuid) from public, anon, authenticated;

create or replace function public.role_rsvps_after_roles() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform sync_role_rsvps(new.event_id);
  return null;
end $$;
drop trigger if exists role_rsvps_after_roles on public.event_roles;
create trigger role_rsvps_after_roles after insert or update on public.event_roles for each row execute function public.role_rsvps_after_roles();

-- Roles set while the event was a draft (or not taking RSVPs) get their RSVPs once it's published / takes RSVPs.
create or replace function public.role_rsvps_after_event() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (old.draft and not new.draft) or old.reg_mode is distinct from new.reg_mode then perform sync_role_rsvps(new.id); end if;
  return null;
end $$;
drop trigger if exists role_rsvps_after_event on public.events;
create trigger role_rsvps_after_event after update on public.events for each row execute function public.role_rsvps_after_event();

-- Event stats: rsvps = everyone RSVP'd (the headcount), seats = how many of the seat limit are taken.
drop function if exists public.event_stats();
create function public.event_stats()
returns table (event_id uuid, rsvps int, attended int, seats int)
language sql stable security definer set search_path = public as $$
  select e.id,
    ((select count(*) from rsvps r where r.event_id = e.id) + (select count(*) from guest_rsvps g where g.event_id = e.id))::int,
    (select count(*) from attendance a where a.event_id = e.id)::int,
    seats_taken(e.id)
  from events e
  where (e.cat <> 'officer_meeting' or is_officer() or is_test_admin()) and e.test = is_test()
$$;
grant execute on function public.event_stats() to anon, authenticated;

-- RSVP the officers already on roles for upcoming events.
select public.sync_role_rsvps(event_id) from public.event_roles;
