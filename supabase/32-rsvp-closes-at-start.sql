-- WFA update: RSVPs close when an event starts (Mountain Time). People who show up without an RSVP
-- still check in with the code on screen, the same as before. Run once in Supabase -> SQL Editor. Safe to run again.

drop policy if exists "members rsvp for themselves" on public.rsvps;
create policy "members rsvp for themselves" on public.rsvps for insert with check (
  auth.uid() is not null and email = jwt_email()
  and exists (select 1 from events e where e.id = event_id
              and now() < (e.date + e.start_time) at time zone 'America/Denver'));
