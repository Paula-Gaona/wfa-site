-- WFA update: when someone joins, their guest check-ins and guest RSVPs move to their account if they match the email,
-- OR the UVU ID when the account's email is that UVU ID's own @uvu.edu address (e.g. 12345678@uvu.edu). That email is
-- confirmed at sign-up, so nobody can take a guest's history by typing someone else's UVU ID on their profile.
-- Run once in Supabase -> SQL Editor, after 111. Safe to run again (replaces the first version of 112).
create or replace function public.claim_guest_checkins() returns trigger
language plpgsql security definer set search_path = public as $$
declare u text := coalesce(substring(lower(new.email) from '^(\d{8})@uvu\.edu$'), '');
begin
  insert into attendance (event_id, email)
    select g.event_id, new.email from guest_checkins g
    where g.email = lower(new.email) or (u <> '' and g.uvid = u)
  on conflict do nothing;
  delete from guest_checkins g where g.email = lower(new.email) or (u <> '' and g.uvid = u);
  with moved as (delete from guest_rsvps g where g.email = lower(new.email) or (u <> '' and g.uvid = u) returning event_id)
  insert into rsvps (event_id, email) select distinct event_id, new.email from moved on conflict do nothing;
  return new;
end $$;
drop trigger if exists members_claim_guest_checkins on public.members;
create trigger members_claim_guest_checkins after insert on public.members
  for each row execute function public.claim_guest_checkins();
