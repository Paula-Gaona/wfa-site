-- WFA update: quick scheduling works again with the simpler approvals (82). While an admin has quick scheduling on,
-- a bigger event (case competition, excursion, guest speaker, career fair) that an ADMIN sends publishes right away
-- instead of going to the three presidents. Everyone else's bigger events still go to the presidents.
-- Run once in Supabase -> SQL Editor, after 82-simpler-event-approvals.sql. Safe to run again.

create or replace function public.send_for_signoff(p_event uuid) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); ev events; r event_requests;
begin
  if not public.is_officer() then return 'err:notofficer'; end if;
  select * into ev from events where id = p_event;
  if ev.id is null then return 'err:missing'; end if;
  if not ev.draft or not big_event(ev.cat) then return 'err:state'; end if;
  if trim(coalesce(ev.descr, '')) = '' then return 'err:desc'; end if;
  select * into r from event_requests where event_id = p_event;
  if r.status in ('sent', 'submitted') then return 'err:uvu'; end if;
  if r.status in ('signoff', 'published') then return 'err:state'; end if;
  insert into event_requests (event_id, form) values (p_event, '{}') on conflict (event_id) do nothing;
  update event_requests set sent_by = coalesce(sent_by, me), sent_at = now(), note = '', signoff_note = '', returned_from = null,
    branch = coalesce(branch, (select p.branch from officer_profiles p where p.email = me)) where event_id = p_event;
  -- Quick scheduling: an admin's own event skips the presidents.
  if public.rq_quick() and public.is_admin() then
    perform rq_publish(p_event, me, 'Published by an admin (quick scheduling).');
    update events set published_at = coalesce(published_at, now()) where id = p_event;
    return 'ok:published';
  end if;
  perform rq_start_round(p_event, 'signoff', me);   -- a president who sends it counts as approving
  return 'ok';
end $$;
grant execute on function public.send_for_signoff(uuid) to authenticated;
