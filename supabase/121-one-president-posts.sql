-- WFA update: one president's approval posts an event.
-- Bigger events (case competitions, excursions, guest speakers, panels, career fairs) used to need every president
-- (or 2 of 3 after two business days). Now the event is posted as soon as one president approves it. A president
-- who sends it themselves counts as that approval. Sending it back with notes still stops it.
-- (The old presidents' review before UVU keeps its rule, for any request still in it.)
-- Run once in Supabase -> SQL Editor, after 82. Safe to run again.

create or replace function public.rq_check_round(p_event uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r event_requests; n int; yes int; note text := '';
begin
  select * into r from event_requests where event_id = p_event;
  if r.status not in ('review', 'signoff') then return; end if;
  if rq_small_signoff(r) then
    if exists (select 1 from rq_small_approvers(r) e where r.votes ? e) then perform rq_publish(p_event, 'system', 'Signed off.'); end if;
    return;
  end if;
  if r.status = 'signoff' then
    if exists (select 1 from wfa_presidents() e where r.votes ? e) then perform rq_publish(p_event, 'system', 'A president approved.'); end if;
    return;
  end if;
  select count(*), count(*) filter (where r.votes ? e) into n, yes from wfa_presidents() e;
  if yes < n then
    if not rq_majority(r) or yes * 2 < n then return; end if;
    note := format('Passed by majority (%s of %s presidents approved).', yes, n);
  else note := 'Every president approved.'; end if;
  perform rq_move(p_event, 'sent', 'system', note);
end $$;
revoke execute on function public.rq_check_round(uuid) from public, anon, authenticated;
