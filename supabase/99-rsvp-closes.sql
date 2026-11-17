-- WFA update: events can stop taking RSVPs at a set date and time (Edit event -> "When do RSVPs close?").
-- Empty = RSVPs stay open until the event starts (or the seats fill up). Officers can still RSVP people after.
-- Run once in Supabase -> SQL Editor, after 98. Safe to run again.

alter table public.events add column if not exists rsvp_closes timestamptz;   -- null = until the event starts

-- Member RSVPs. Waitlist promotions (adding someone else) still go through after RSVPs close.
create or replace function public.no_draft_rsvps() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from events e where e.id = new.event_id and e.draft) then
    raise exception 'RSVPs open when the event is published.';
  end if;
  if not public.is_officer() and exists (select 1 from events e where e.id = new.event_id and e.rsvp_opens > now()) then
    raise exception 'RSVPs for this event aren''t open yet.';
  end if;
  if not public.is_officer() and new.email = public.jwt_email()
     and exists (select 1 from events e where e.id = new.event_id and e.rsvp_closes <= now()) then
    raise exception 'RSVPs for this event are closed.';
  end if;
  return new;
end $$;

-- Guest RSVPs.
create or replace function public.guest_rsvps_closed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_officer() and exists (select 1 from events e where e.id = new.event_id and e.rsvp_closes <= now()) then
    raise exception 'RSVPs for this event are closed.';
  end if;
  return new;
end $$;
drop trigger if exists guest_rsvps_closed on public.guest_rsvps;
create trigger guest_rsvps_closed before insert on public.guest_rsvps for each row execute function public.guest_rsvps_closed();
