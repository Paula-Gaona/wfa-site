-- WFA update: simpler event approvals, and three kinds of registration.
--
-- 1. The scheduling form is optional. Officers can still fill it out and send it to the event schedulers to confirm a
--    room or setup with UVU, but it no longer gates publishing, and there's no branch review or presidents' review
--    before UVU any more.
-- 2. Smaller events (anything but case competitions, excursions, guest speakers, and career fairs) publish like
--    before the scheduling system: leadership publishes them, and other officers send them to leadership.
-- 3. Bigger events need all three presidents to approve before they're published. If one hasn't answered 2 business
--    days after it was sent, 2 of the 3 is enough. A president who sends it back stops it; it goes back to the
--    officer with their notes, and they send it again when it's fixed.
-- 4. Each event has a registration type: RSVP on this site, no button, or a link to another registration page (for
--    posting other organizations' events). Linked events don't take RSVPs, check-ins, or points.
--
-- Run once in Supabase -> SQL Editor, after 81. Safe to run again.

-- ---------- Registration type ----------
alter table public.events add column if not exists reg_mode text not null default 'rsvp';
alter table public.events add column if not exists reg_url text not null default '';
alter table public.events drop constraint if exists events_reg_mode_check;
alter table public.events add constraint events_reg_mode_check check (reg_mode in ('rsvp', 'none', 'link'));
alter table public.events drop constraint if exists events_reg_url_check;
alter table public.events add constraint events_reg_url_check check (reg_mode <> 'link' or reg_url ~* '^https?://\S+\.\S+');

-- Only "RSVP on this site" events take RSVPs, guest RSVPs, or waitlist sign-ups.
create or replace function public.rsvp_mode_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from events e where e.id = new.event_id and e.reg_mode <> 'rsvp') then
    raise exception 'This event doesn''t take RSVPs on this site.';
  end if;
  return new;
end $$;
drop trigger if exists rsvp_mode_guard on public.rsvps;
create trigger rsvp_mode_guard before insert on public.rsvps for each row execute function public.rsvp_mode_guard();
drop trigger if exists rsvp_mode_guard on public.guest_rsvps;
create trigger rsvp_mode_guard before insert on public.guest_rsvps for each row execute function public.rsvp_mode_guard();
drop trigger if exists rsvp_mode_guard on public.waitlist;
create trigger rsvp_mode_guard before insert on public.waitlist for each row execute function public.rsvp_mode_guard();

-- Events linked to another registration page aren't WFA events: no check-in or points.
create or replace function public.checkin_mode_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from events e where e.id = new.event_id and e.reg_mode = 'link') then
    raise exception 'This event is run by another organization, so there''s no WFA check-in.';
  end if;
  return new;
end $$;
drop trigger if exists checkin_mode_guard on public.attendance;
create trigger checkin_mode_guard before insert on public.attendance for each row execute function public.checkin_mode_guard();
drop trigger if exists checkin_mode_guard on public.guest_checkins;
create trigger checkin_mode_guard before insert on public.guest_checkins for each row execute function public.checkin_mode_guard();

-- ---------- Publishing ----------
-- Smaller events publish without the presidents. Bigger events still need the presidents' sign-off.
create or replace function public.guard_event_publish() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or new.draft or new.cat = 'officer_meeting' or not big_event(new.cat) then return new; end if;
  if tg_op = 'UPDATE' and not old.draft then return new; end if;     -- already published: normal edits are fine
  if not exists (select 1 from event_requests r where r.event_id = new.id and r.status = 'published') then
    raise exception 'Case competitions, excursions, guest speakers, and career fairs are published once the presidents approve them. Use Send to the presidents.';
  end if;
  return new;
end $$;

-- The optional scheduling form goes straight to the event schedulers (no branch review or presidents' review first).
create or replace function public.save_event_request(p_event uuid, p_form jsonb, p_send boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); r event_requests; cat text;
begin
  if not public.is_officer() then return 'err:notofficer'; end if;
  select e.cat into cat from events e where e.id = p_event;
  if cat is null or cat = 'officer_meeting' then return 'err:event'; end if;
  select * into r from event_requests where event_id = p_event;
  if r.status is not null and r.status not in ('draft', 'returned') then return 'err:locked'; end if;
  insert into event_requests (event_id, form) values (p_event, coalesce(p_form, '{}'))
    on conflict (event_id) do update set form = excluded.form;
  if not p_send then return 'ok'; end if;
  update event_requests set sent_by = coalesce(sent_by, me), sent_at = now(), note = '', returned_from = null,
    branch = coalesce(branch, (select p.branch from officer_profiles p where p.email = me)) where event_id = p_event;
  perform rq_move(p_event, 'sent', me);
  if public.is_scheduler() then update event_requests set nudged_at = now() where event_id = p_event; end if;   -- they handle it themselves
  return 'ok';
end $$;
grant execute on function public.save_event_request(uuid, jsonb, boolean) to authenticated;

-- Send a bigger event to the presidents. Any officer can, once it has a description. Not while the scheduling form is
-- with the schedulers (wait for them to confirm it or send it back).
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
  perform rq_start_round(p_event, 'signoff', me);   -- a president who sends it counts as approving
  return 'ok';
end $$;
grant execute on function public.send_for_signoff(uuid) to authenticated;

-- Majority rules for bigger events: 2 business days after it was sent, with no objections. (The old presidents'
-- review before UVU keeps its rule, for any request still in it.)
create or replace function public.rq_majority(r event_requests) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when r.status = 'review' then coalesce(r.rounds, 0) >= 2 or (r.step_started_at is not null and now() >= business_add(r.step_started_at, 120))
    when r.status = 'signoff' and big_event((select e.cat from events e where e.id = r.event_id))
      then r.status_at is not null and now() >= business_add(r.status_at, 48) and coalesce(r.objections, '{}'::jsonb) = '{}'::jsonb
    else false end;
$$;

-- A president's vote. Same as 53-guest-approvals-and-application-questions.sql, except that sending a sign-off back
-- always stops it: it goes back to the officer who sent it (not to the scheduler), with the president's notes.
create or replace function public.president_vote(p_event uuid, p_ok boolean, p_note text default '', p_changes jsonb default '[]',
  p_note_kind text default 'context', p_snapshot jsonb default null) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); r event_requests; n int; no int; msg text;
begin
  select * into r from event_requests where event_id = p_event;
  if r.status is null or r.status not in ('review', 'signoff') then return 'err:state'; end if;
  if not (exists (select 1 from wfa_presidents() e where e = me) or (rq_small_signoff(r) and exists (select 1 from rq_small_approvers(r) e where e = me))) then
    return 'err:notpresident';
  end if;
  if p_ok then
    update event_requests set votes = votes || jsonb_build_object(me, now()), objections = objections - me,
      history = history || jsonb_build_array(jsonb_build_object('at', now(), 'by', me, 'status', 'vote', 'note', ''))
      where event_id = p_event;
    perform rq_check_round(p_event);
    return 'ok';
  end if;
  if trim(coalesce(p_note, '')) = '' and jsonb_array_length(coalesce(p_changes, '[]')) = 0 then return 'err:note'; end if;
  update event_requests set votes = votes - me,
    suggestions = suggestions || jsonb_build_array(jsonb_build_object('by', me, 'at', now(), 'step', r.status, 'state', 'open',
      'note', trim(coalesce(p_note, '')), 'note_kind', case when p_note_kind = 'more' then 'more' else 'context' end,
      'changes', coalesce(p_changes, '[]'), 'snapshot', p_snapshot, 'replies', '{}'::jsonb))
    where event_id = p_event;
  if r.status = 'review' and rq_majority(r) then
    update event_requests set objections = objections || jsonb_build_object(me, now()),
      history = history || jsonb_build_array(jsonb_build_object('at', now(), 'by', me, 'status', 'objection', 'note', trim(coalesce(p_note, ''))))
      where event_id = p_event;
    select * into r from event_requests where event_id = p_event;
    select count(*), count(*) filter (where r.objections ? e) into n, no from wfa_presidents() e;
    if no * 2 <= n then perform rq_check_round(p_event); return 'ok'; end if;
  end if;
  update event_requests set rounds = coalesce(rounds, 0) + 1 where event_id = p_event;
  msg := coalesce(nullif(trim(p_note), ''), 'Suggested changes.');
  if r.status = 'review' then
    update event_requests set note = left(msg, 4000), returned_from = 'review' where event_id = p_event;
    if r.branch_by is not null then perform rq_move(p_event, 'branch', me, 'Back to branch leadership: ' || msg);
    else perform rq_move(p_event, 'returned', me, msg); end if;
  else
    update event_requests set note = left(msg, 4000), signoff_note = left(msg, 4000), returned_from = 'signoff' where event_id = p_event;
    perform rq_move(p_event, 'returned', me, 'Changes requested: ' || msg);
  end if;
  return 'ok';
end $$;
grant execute on function public.president_vote(uuid, boolean, text, jsonb, text, jsonb) to authenticated;

-- Runs every 10 minutes from the automatic-emails function. Bigger events: after 2 business days, 2 of 3 approvals
-- is enough (rq_check_round decides). Everything else works as before.
create or replace function public.request_timeouts() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select q.event_id, q.status from event_requests q join events e on e.id = q.event_id
             where q.status in ('review', 'signoff') and now() >= business_add(q.status_at, 48) loop
    if r.status = 'signoff' and big_event((select e.cat from events e where e.id = r.event_id)) then
      perform rq_check_round(r.event_id);
      if exists (select 1 from event_requests q where q.event_id = r.event_id and q.status = 'published') then n := n + 1; end if;
    elsif r.status = 'review' then
      perform rq_move(r.event_id, 'sent', 'system', 'No objections in 48 hours.'); n := n + 1;
    elsif exists (select 1 from wfa_presidents() p join event_requests q on q.status_by = p where q.event_id = r.event_id) then
      perform rq_publish(r.event_id, 'system', 'No objections in 48 hours.'); n := n + 1;
    end if;
  end loop;
  for r in select id from guest_requests g where status = 'review' and now() >= business_add(status_at, 48)
             and exists (select 1 from wfa_presidents() e where e = g.sent_by) loop
    perform gq_move(r.id, 'sent', 'system', 'No objections in 48 hours.');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.request_timeouts() from public, anon, authenticated;
grant execute on function public.request_timeouts() to service_role;

-- Requests waiting on branch leadership or the presidents' review before UVU skip ahead to the schedulers.
update public.event_requests set status = 'sent', status_at = now(), nudged_at = null,
  history = history || jsonb_build_array(jsonb_build_object('at', now(), 'by', 'system', 'status', 'sent', 'note', 'Branch and presidents'' review before UVU are no longer needed.'))
  where status in ('branch', 'review');
