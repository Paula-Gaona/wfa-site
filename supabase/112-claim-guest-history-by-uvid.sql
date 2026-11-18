-- WFA update: when someone joins (or adds their UVU ID to their profile), guest check-ins and guest RSVPs move to
-- their account if they match the email OR the UVU ID, so a guest doesn't have to join with the same email.
-- Run once in Supabase -> SQL Editor, after 111. Safe to run again.
create or replace function public.claim_guest_checkins() returns trigger
language plpgsql security definer set search_path = public as $$
declare u text := coalesce(new.uvuid, '');
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
create trigger members_claim_guest_checkins after insert or update of uvuid, email on public.members
  for each row execute function public.claim_guest_checkins();
