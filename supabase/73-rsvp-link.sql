-- WFA update: an event's RSVP button can link to another site (Officer tools -> the event's "RSVP link"). Leave it blank
-- for the usual RSVP. With a link, clicking is what counts here: a signed-in member's click saves an RSVP under their
-- name (so reminders, no-shows, and stats keep working), and a visitor without an account adds 1 to a count. The other
-- site handles the seat limit, so these events don't fill up or have a waitlist here.
-- Run once in Supabase -> SQL Editor, after 62-rsvp-waitlist.sql. Safe to run again.

alter table public.events add column if not exists rsvp_url text not null default '';
alter table public.events add column if not exists rsvp_link_clicks int not null default 0;
alter table public.events drop constraint if exists events_rsvp_url_ok;
alter table public.events add constraint events_rsvp_url_ok check (rsvp_url = '' or (char_length(rsvp_url) <= 500 and rsvp_url ~* '^https?://[^\s]+$'));

-- Someone clicked the link. Returns 'member', 'visitor', or a reason it wasn't counted (the link opens either way).
create or replace function public.rsvp_link_click(p_event uuid) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); e events;
begin
  select * into e from events where id = p_event;
  if e.id is null or e.draft or e.rsvp_url = '' or e.test is distinct from is_test() or e.cat in ('officer_meeting', 'case_competition') then return 'missing'; end if;
  if now() >= (e.date + e.start_time) at time zone 'America/Denver' then return 'started'; end if;
  if auth.uid() is not null and me is not null then
    begin
      insert into rsvps (event_id, email) values (p_event, me) on conflict (event_id, email) do nothing;
    exception when raise_exception then return 'notyet';
    end;
    return 'member';
  end if;
  if e.members_only then return 'members'; end if;
  if e.guest_rsvp_opens is not null and now() < e.guest_rsvp_opens then return 'notyet'; end if;
  update events set rsvp_link_clicks = rsvp_link_clicks + 1 where id = p_event;
  return 'visitor';
end $$;
grant execute on function public.rsvp_link_click(uuid) to anon, authenticated;

-- Same as 62, except events with an RSVP link have no seat limit or waitlist here.
create or replace function public.check_capacity() returns trigger
language plpgsql security definer set search_path = public as $$
declare c int; u text;
begin
  select cap, rsvp_url into c, u from events where id = new.event_id;
  if u <> '' then return new; end if;
  if c > 0 and seats_taken(new.event_id) >= c then raise exception 'This event is full.'; end if;
  if c > 0 and exists (select 1 from waitlist w where w.event_id = new.event_id and w.promoted_at is null and w.email <> new.email)
     and not exists (select 1 from waitlist w where w.event_id = new.event_id and w.email = new.email) then
    raise exception 'This event has a waitlist. Join the waitlist instead.';
  end if;
  return new;
end $$;

-- RSVP counts on the site include visitors who clicked the link.
create or replace function public.event_stats()
returns table (event_id uuid, rsvps int, attended int)
language sql stable security definer set search_path = public as $$
  select e.id,
    ((select count(*) from rsvps r where r.event_id = e.id) + (select count(*) from guest_rsvps g where g.event_id = e.id) + e.rsvp_link_clicks)::int,
    (select count(*) from attendance a where a.event_id = e.id)::int
  from events e
  where (e.cat <> 'officer_meeting' or is_officer() or is_test_admin()) and e.test = is_test()
$$;
