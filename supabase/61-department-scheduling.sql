-- WFA update: simpler scheduling now that the WFA is a department organization.
--   1. Branch review (regular officers' events) stays.
--   2. The presidents' review before UVU is gone. After branch review (or right away for presidents, VPs, the
--      advisor, and admins), the event goes to one lighter step: "Confirming with UVU". An event scheduler confirms it
--      with UVU and marks it confirmed (no separate "submitted" step). The officer who sent it can still edit the
--      request during that step, since plans are easier to change with the department.
--   3. The scheduler sets the final details and sends it to the presidents' sign-off, which is unchanged. It
--      publishes once they sign off.
--   4. External guest approvals are retired (the guest form is now a downloadable document). Guest requests still in
--      progress are set back to drafts so nobody gets more reminders about them; nothing is deleted.
-- Run once in Supabase -> SQL Editor, after 60. Safe to run again.

-- Who can still edit the request during the UVU step: the officer who sent it, or any event scheduler.
create or replace function public.rq_uvu_handler(r event_requests) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_scheduler() or r.sent_by = public.jwt_email();
$$;

-- Save the form, and optionally send it on. The sender (or a scheduler) can still edit it while it's being confirmed
-- with UVU; branch leadership can edit it while reviewing it.
create or replace function public.save_event_request(p_event uuid, p_form jsonb, p_send boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); r event_requests; cat text; target text;
begin
  if not public.is_officer() then return 'err:notofficer'; end if;
  select e.cat into cat from events e where e.id = p_event;
  if cat is null or cat = 'officer_meeting' then return 'err:event'; end if;
  select * into r from event_requests where event_id = p_event;
  if r.status is not null and r.status not in ('draft', 'returned')
     and not (r.status = 'branch' and not p_send and (public.is_admin() or exists (select 1 from branch_reviewers(r.branch) e where e = me)))
     and not (r.status in ('sent', 'approved') and not p_send and rq_uvu_handler(r)) then
    return 'err:locked';
  end if;
  insert into event_requests (event_id, form) values (p_event, coalesce(p_form, '{}'))
    on conflict (event_id) do update set form = excluded.form;
  if not p_send then return 'ok'; end if;
  -- A resend goes back to the step that sent it back; a first send starts with branch review if they need it.
  target := case when r.status = 'returned' and r.returned_from = 'branch' then 'branch'
                 when r.status = 'returned' and r.returned_from is not null then 'sent'
                 when needs_branch_review(me) then 'branch'
                 else 'sent' end;
  update event_requests set sent_by = coalesce(sent_by, me), sent_at = now(), note = '', returned_from = null,
    branch = coalesce(branch, (select p.branch from officer_profiles p where p.email = me)) where event_id = p_event;
  perform rq_move(p_event, target, me);
  return 'ok';
end $$;
grant execute on function public.save_event_request(uuid, jsonb, boolean) to authenticated;

-- Branch review: approve (it goes to the UVU step) or send it back with notes.
create or replace function public.branch_review(p_event uuid, p_ok boolean, p_note text default '') returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); r event_requests;
begin
  select * into r from event_requests where event_id = p_event;
  if r.status is distinct from 'branch' then return 'err:state'; end if;
  if not (public.is_admin() or exists (select 1 from branch_reviewers(r.branch) e where e = me)) then return 'err:notreviewer'; end if;
  if not p_ok then
    if trim(coalesce(p_note, '')) = '' then return 'err:note'; end if;
    update event_requests set note = left(trim(p_note), 4000), returned_from = 'branch' where event_id = p_event;
    perform rq_move(p_event, 'returned', me, trim(p_note)); return 'ok';
  end if;
  update event_requests set branch_by = me, returned_from = null where event_id = p_event;
  perform rq_move(p_event, 'sent', me, coalesce(nullif(trim(p_note), ''), 'Approved by branch leadership.'));
  return 'ok';
end $$;
grant execute on function public.branch_review(uuid, boolean, text) to authenticated;

-- The UVU step (event schedulers): mark it confirmed by UVU, send it back with notes, or (once confirmed and
-- finalized) send it to the presidents' sign-off.
create or replace function public.scheduler_update(p_event uuid, p_status text, p_note text default '') returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); r event_requests;
begin
  select * into r from event_requests where event_id = p_event;
  if r.status is null then return 'err:missing'; end if;
  if not public.is_scheduler() then return 'err:notscheduler'; end if;
  if p_status = 'returned' then
    if r.status not in ('sent', 'submitted', 'approved') then return 'err:state'; end if;
    if trim(coalesce(p_note, '')) = '' then return 'err:note'; end if;
    update event_requests set note = left(trim(p_note), 4000), returned_from = 'sent' where event_id = p_event;
    perform rq_move(p_event, 'returned', me, trim(p_note));
  elsif p_status in ('approved', 'submitted') then
    if r.status not in ('sent', 'submitted') then return 'err:state'; end if;
    perform rq_move(p_event, 'approved', me, coalesce(nullif(trim(p_note), ''), 'Confirmed with UVU.'));
  elsif p_status = 'signoff' then
    if r.status <> 'approved' then return 'err:state'; end if;
    update event_requests set signoff_note = '' where event_id = p_event;
    perform rq_start_round(p_event, 'signoff', me);
  else return 'err:status'; end if;
  return 'ok';
end $$;
grant execute on function public.scheduler_update(uuid, text, text) to authenticated;

-- Requests already partway through the old steps: the presidents' review and "submitted to UVU" both become
-- "Confirming with UVU".
update public.event_requests set status = 'sent', status_at = now(), nudged_at = null, votes = '{}', objections = '{}',
  history = history || jsonb_build_array(jsonb_build_object('at', now(), 'by', 'system', 'status', 'sent', 'note', 'Scheduling was simplified: this is now confirmed with UVU directly.'))
  where status in ('review', 'submitted');

-- Guest approvals in progress go back to drafts (no more reminders). Approved ones and their history stay.
update public.guest_requests set status = 'draft', nudged_at = null
  where status in ('branch', 'review', 'sent', 'returned', 'submitted');

-- The publishing guard's message.
create or replace function public.guard_event_publish() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or new.draft or new.cat = 'officer_meeting' then return new; end if;
  if tg_op = 'UPDATE' and not old.draft then return new; end if;     -- already published: normal edits are fine
  if not exists (select 1 from event_requests r where r.event_id = new.id and r.status = 'published') then
    raise exception 'This event is published after it''s confirmed with UVU and the presidents sign off. Send it through Scheduling.';
  end if;
  return new;
end $$;
