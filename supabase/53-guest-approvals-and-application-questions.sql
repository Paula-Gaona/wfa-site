-- WFA update:
-- 1. External guest pre-approval. Officers can get a speaker (or judge, panelist...) approved by UVU before the event
--    itself is planned, with rough estimates of the whole event. Steps:
--      * regular officers: their branch president or VP reviews it (and can edit it). If a president approves it
--        there, it goes straight to the schedulers; if a VP does, it goes on to the presidents.
--      * presidents' step: one president (not the sender or the VP who approved it) approves it, and can edit it
--        first. After 36 business hours, other vice presidents can approve too. It only moves on automatically
--        (after 48 business hours) when a president sent it. Sending it back returns it to whoever edits it: the
--        branch leadership if there was a branch review, otherwise the sender.
--      * a scheduler submits it to UVU and marks it approved. The approval window is the semester of the guest's
--        likely date (Spring Jan 1-Apr 30, Summer May 1-Jul 31, Fall Aug 1-Dec 31); the scheduler can narrow it.
--    Approved guests can be picked on an event's scheduling request. Nothing here goes on the calendar.
-- 2. Events: when presidents send back an officer's event in their review, it goes to the branch leadership to edit
--    (not the officer). A president's comment is marked "just context" or "more changes"; with "more changes", making
--    their field edits doesn't count as their approval. Each request for changes keeps a snapshot, so presidents can
--    see what was changed since. Events can show their external guests (name, title, company, bio) on the event page,
--    and Q&A questions can be addressed to specific guests. Officers can RSVP as soon as an event is published.
-- 3. Admins can edit the officer application's questions. Answers are saved with the question text they answered.
-- Run once in Supabase -> SQL Editor, after 52. Safe to run again.

-- ---------- Application questions ----------
alter table public.app_settings add column if not exists questions jsonb;                 -- null = the default questions
alter table public.applications add column if not exists answers jsonb not null default '[]';   -- [{id, label, value}]
alter table public.applications alter column why set default '';
alter table public.applications alter column ideas set default '';

-- ---------- Guests shown on events, and Q&A for specific guests ----------
alter table public.events add column if not exists speakers jsonb not null default '[]';   -- [{name, title, company, bio}]
alter table public.event_questions add column if not exists speakers text[] not null default '{}';   -- empty = all of them
drop function if exists public.ask_question(uuid, text, text);
create or replace function public.ask_question(p_event uuid, p_question text, p_name text default '', p_speakers text[] default '{}') returns text
language plpgsql security definer set search_path = public as $$
declare e events; me text := public.jwt_email(); nm text;
begin
  select * into e from events where id = p_event;
  if e.id is null or not e.qa_enabled or e.draft or e.test <> public.is_test() or (e.members_only and auth.uid() is null) then return 'missing'; end if;
  if now() >= (e.date + e.end_time) at time zone 'America/Denver' then return 'closed'; end if;
  if trim(coalesce(p_question, '')) = '' then return 'empty'; end if;
  if char_length(p_question) > 600 then return 'long'; end if;
  if me is not null then select trim(m.first || ' ' || m.last) into nm from members m where m.email = me; end if;
  if coalesce(nm, '') = '' then nm := left(trim(coalesce(p_name, '')), 80); end if;
  if nm = '' then return 'name'; end if;
  if (select count(*) from event_questions q where q.event_id = p_event and q.created_at > now() - interval '1 hour'
        and ((me is not null and q.email = me) or (me is null and q.email is null and q.name = nm))) >= 5 then return 'many'; end if;
  insert into event_questions (event_id, email, name, question, speakers) values (p_event, me, nm, trim(p_question), coalesce(p_speakers, '{}'));
  return 'ok';
end $$;
grant execute on function public.ask_question(uuid, text, text, text[]) to anon, authenticated;

-- ---------- RSVPs: officers can RSVP as soon as an event is published, before RSVPs open for everyone ----------
create or replace function public.no_draft_rsvps() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from events e where e.id = new.event_id and e.draft) then
    raise exception 'RSVPs open when the event is published.';
  end if;
  if not public.is_officer() and exists (select 1 from events e where e.id = new.event_id and e.rsvp_opens > now()) then
    raise exception 'RSVPs for this event aren''t open yet.';
  end if;
  return new;
end $$;

-- ---------- Events: branch leadership fixes presidents' changes; comment types; snapshots ----------
alter table public.event_requests add column if not exists branch_by text;   -- who approved it in the branch review
create or replace function public.branch_review(p_event uuid, p_ok boolean, p_note text default '') returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); r event_requests; cat text;
begin
  select * into r from event_requests where event_id = p_event;
  if r.status is distinct from 'branch' then return 'err:state'; end if;
  if not (public.is_admin() or exists (select 1 from branch_reviewers(r.branch) e where e = me)) then return 'err:notreviewer'; end if;
  if not p_ok then
    if trim(coalesce(p_note, '')) = '' then return 'err:note'; end if;
    update event_requests set note = left(trim(p_note), 4000), returned_from = 'branch' where event_id = p_event;
    perform rq_move(p_event, 'returned', me, trim(p_note)); return 'ok';
  end if;
  update event_requests set branch_by = me where event_id = p_event;
  select e.cat into cat from events e where e.id = p_event;
  if trim(coalesce(p_note, '')) <> '' and big_event(cat) then
    update event_requests set history = history || jsonb_build_array(jsonb_build_object('at', now(), 'by', me, 'status', 'branch_ok', 'note', trim(p_note)))
      where event_id = p_event;
  end if;
  if big_event(cat) then perform rq_start_round(p_event, 'review', me);
  else perform rq_move(p_event, 'sent', me, coalesce(nullif(trim(p_note), ''), 'Approved by branch leadership.')); end if;
  return 'ok';
end $$;
grant execute on function public.branch_review(uuid, boolean, text) to authenticated;

-- A president whose comment says "more changes" isn't counted as approving just because their field edits were made.
create or replace function public.rq_start_round(p_event uuid, p_status text, p_by text) returns void
language plpgsql security definer set search_path = public as $$
declare r event_requests; ev events; s jsonb; out jsonb := '[]'; v jsonb := '{}';
begin
  select * into r from event_requests where event_id = p_event;
  if r.step_kind is distinct from p_status then
    update event_requests set step_kind = p_status, step_started_at = now(), rounds = 0 where event_id = p_event;
  end if;
  perform rq_move(p_event, p_status, p_by);
  select * into r from event_requests where event_id = p_event;
  select * into ev from events where id = p_event;
  if exists (select 1 from wfa_presidents() e where e = p_by) then v := jsonb_build_object(p_by, now()); end if;
  for s in select x from jsonb_array_elements(r.suggestions) x loop
    if s->>'step' = p_status and s->>'state' = 'open' then
      if jsonb_array_length(coalesce(s->'changes', '[]')) > 0 and coalesce(s->>'note_kind', '') <> 'more'
         and not exists (select 1 from jsonb_array_elements(s->'changes') c where not rq_change_met(ev, r.form, c)) then
        v := v || jsonb_build_object(s->>'by', now()); s := s || '{"state": "met"}';
      else s := s || '{"state": "answered"}'; end if;
    end if;
    out := out || jsonb_build_array(s);
  end loop;
  update event_requests set votes = v, suggestions = out where event_id = p_event;
  perform rq_check_round(p_event);
end $$;

-- Presidents' changes: p_note_kind is 'context' or 'more'; p_snapshot is the event and form as the president saw them.
-- In the presidents' review, an officer's event goes back to the branch leadership (status 'branch') to fix.
drop function if exists public.president_vote(uuid, boolean, text, jsonb);
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
  if rq_majority(r) then
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
    update event_requests set signoff_note = left(coalesce(nullif(trim(p_note), ''), 'See the suggested changes.'), 4000) where event_id = p_event;
    perform rq_move(p_event, 'approved', me, 'Changes requested: ' || coalesce(nullif(trim(p_note), ''), 'see the suggestions'));
  end if;
  return 'ok';
end $$;
grant execute on function public.president_vote(uuid, boolean, text, jsonb, text, jsonb) to authenticated;

-- Branch leadership fixing presidents' changes can say why they didn't make some (like the sender can).
create or replace function public.reply_suggestions(p_event uuid, p_replies jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); r event_requests; s jsonb; out jsonb := '[]';
begin
  select * into r from event_requests where event_id = p_event;
  if not (r.sent_by = me or public.is_scheduler() or exists (select 1 from branch_reviewers(r.branch) e where e = me)) then return 'err:notallowed'; end if;
  for s in select x from jsonb_array_elements(r.suggestions) x loop
    if s->>'state' = 'open' and p_replies ? (s->>'by') then
      s := jsonb_set(s, '{replies}', coalesce(s->'replies', '{}') || (p_replies->(s->>'by')));
    end if;
    out := out || jsonb_build_array(s);
  end loop;
  update event_requests set suggestions = out where event_id = p_event;
  return 'ok';
end $$;
grant execute on function public.reply_suggestions(uuid, jsonb) to authenticated;

-- ---------- External guest approvals ----------
create table if not exists public.guest_requests (
  id uuid primary key default gen_random_uuid(),
  form jsonb not null default '{}',
  status text not null default 'draft'
    check (status in ('draft', 'branch', 'review', 'sent', 'returned', 'submitted', 'approved', 'removed')),
  note text not null default '',
  sent_by text not null default public.jwt_email(),
  branch text,
  branch_by text,             -- who approved it in the branch review
  votes jsonb not null default '{}',
  status_at timestamptz not null default now(),
  status_by text,
  returned_from text,
  history jsonb not null default '[]',
  nudged_at timestamptz,
  window_start date,          -- UVU's approval window (inside the semester)
  window_end date,
  created_at timestamptz not null default now()
);
alter table public.guest_requests add column if not exists branch_by text;
alter table public.guest_requests enable row level security;
drop policy if exists "officers see guest requests" on public.guest_requests;
create policy "officers see guest requests" on public.guest_requests for select using (public.is_officer());
grant select on public.guest_requests to authenticated;
grant select, insert, update, delete on public.guest_requests to service_role;

create or replace function public.gq_move(p_id uuid, p_status text, p_by text, p_note text default '') returns void
language sql security definer set search_path = public as $$
  update guest_requests set status = p_status, status_at = now(), status_by = p_by, nudged_at = null,
    history = history || jsonb_build_array(jsonb_build_object('at', now(), 'by', p_by, 'status', p_status, 'note', coalesce(p_note, '')))
    where id = p_id;
$$;
-- Who can approve a guest in the presidents' step: presidents other than the sender and whoever sent it to this step;
-- once it has waited 36 business hours (and a president didn't send it), vice presidents other than those two as well.
create or replace function public.gq_approvers(g guest_requests) returns setof text
language sql stable security definer set search_path = public as $$
  select e from wfa_presidents() e where e is distinct from g.sent_by and e is distinct from g.status_by
  union
  select v from wfa_vps() v where v is distinct from g.sent_by and v is distinct from g.status_by
    and not exists (select 1 from wfa_presidents() x where x = g.sent_by)
    and g.status_at is not null and now() >= business_add(g.status_at, 36);
$$;
-- On to the presidents' step (or the schedulers, if there's nobody left to approve it).
create or replace function public.gq_to_review(p_id uuid, p_by text) returns void
language plpgsql security definer set search_path = public as $$
declare sender text;
begin
  select sent_by into sender from guest_requests where id = p_id;
  if exists (select 1 from wfa_presidents() e where e is distinct from sender and e is distinct from p_by) then perform gq_move(p_id, 'review', p_by);
  else perform gq_move(p_id, 'sent', p_by, 'No other president to review it.'); end if;
end $$;
revoke execute on function public.gq_move(uuid, text, text, text), public.gq_to_review(uuid, text) from public, anon, authenticated;

-- Save the form (p_id null = a new one), and optionally send it. The sender edits drafts and sent-back requests; the
-- branch leadership and presidents can edit it while it's waiting on them. Returns the id, or err:...
create or replace function public.save_guest_request(p_id uuid, p_form jsonb, p_send boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); r guest_requests; gid uuid := p_id; target text;
begin
  if not public.is_officer() then return 'err:notofficer'; end if;
  if gid is null then
    insert into guest_requests (form, sent_by, branch) values (coalesce(p_form, '{}'), me, (select p.branch from officer_profiles p where p.email = me)) returning id into gid;
  else
    select * into r from guest_requests where id = gid;
    if r.id is null then return 'err:missing'; end if;
    if r.status in ('draft', 'returned') then
      if r.sent_by <> me and not public.is_admin() then return 'err:notyours'; end if;
    elsif r.status = 'branch' and not p_send and (public.is_admin() or exists (select 1 from branch_reviewers(r.branch) e where e = me)) then null;
    elsif r.status = 'review' and not p_send and exists (select 1 from gq_approvers(r) e where e = me) then null;
    else return 'err:locked'; end if;
    update guest_requests set form = coalesce(p_form, '{}') where id = gid;
  end if;
  if not p_send then return gid::text; end if;
  select * into r from guest_requests where id = gid;
  target := case when r.status = 'returned' and r.returned_from in ('branch', 'review') then r.returned_from
                 when r.status = 'returned' and r.returned_from is not null then 'sent'
                 when needs_branch_review(me) then 'branch' else 'review' end;
  update guest_requests set note = '', returned_from = null where id = gid;
  if target = 'review' then perform gq_to_review(gid, me); else perform gq_move(gid, target, me); end if;
  return gid::text;
end $$;
grant execute on function public.save_guest_request(uuid, jsonb, boolean) to authenticated;

-- Branch review: a president's approval sends it to the schedulers; a VP's sends it to the presidents.
create or replace function public.guest_branch_review(p_id uuid, p_ok boolean, p_note text default '') returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); r guest_requests;
begin
  select * into r from guest_requests where id = p_id;
  if r.status is distinct from 'branch' then return 'err:state'; end if;
  if not (public.is_admin() or exists (select 1 from branch_reviewers(r.branch) e where e = me)) then return 'err:notreviewer'; end if;
  if not p_ok then
    if trim(coalesce(p_note, '')) = '' then return 'err:note'; end if;
    update guest_requests set note = left(trim(p_note), 4000), returned_from = 'branch' where id = p_id;
    perform gq_move(p_id, 'returned', me, trim(p_note)); return 'ok';
  end if;
  update guest_requests set branch_by = me where id = p_id;
  if exists (select 1 from wfa_presidents() e where e = me) then perform gq_move(p_id, 'sent', me, 'Approved by a president in the branch review.');
  else perform gq_to_review(p_id, me); end if;
  return 'ok';
end $$;
grant execute on function public.guest_branch_review(uuid, boolean, text) to authenticated;

-- Presidents' step: approve it on to the schedulers, or send it back (to the branch leadership if there was a branch
-- review, otherwise to the sender).
create or replace function public.guest_vote(p_id uuid, p_ok boolean, p_note text default '') returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); r guest_requests;
begin
  select * into r from guest_requests where id = p_id;
  if r.status is distinct from 'review' then return 'err:state'; end if;
  if not exists (select 1 from gq_approvers(r) e where e = me) then return 'err:notpresident'; end if;
  if not p_ok then
    if trim(coalesce(p_note, '')) = '' then return 'err:note'; end if;
    update guest_requests set note = left(trim(p_note), 4000) where id = p_id;
    if r.branch_by is not null then perform gq_move(p_id, 'branch', me, 'Back to branch leadership: ' || trim(p_note));
    else update guest_requests set returned_from = 'review' where id = p_id; perform gq_move(p_id, 'returned', me, trim(p_note)); end if;
    return 'ok';
  end if;
  perform gq_move(p_id, 'sent', me, 'Approved.');
  return 'ok';
end $$;
grant execute on function public.guest_vote(uuid, boolean, text) to authenticated;

-- The semester a date falls in: Spring Jan 1-Apr 30, Summer May 1-Jul 31, Fall Aug 1-Dec 31.
create or replace function public.semester_bounds(d date, out s date, out e date)
language sql immutable as $$
  select case when extract(month from d) <= 4 then make_date(extract(year from d)::int, 1, 1)
              when extract(month from d) <= 7 then make_date(extract(year from d)::int, 5, 1)
              else make_date(extract(year from d)::int, 8, 1) end,
         case when extract(month from d) <= 4 then make_date(extract(year from d)::int, 4, 30)
              when extract(month from d) <= 7 then make_date(extract(year from d)::int, 7, 31)
              else make_date(extract(year from d)::int, 12, 31) end;
$$;
grant execute on function public.semester_bounds(date) to authenticated;
-- A guest's likely date: the first ideal date on its estimated request.
create or replace function public.gq_likely(g guest_requests) returns date
language sql stable as $$
  select coalesce((select min(x)::date from jsonb_array_elements_text(coalesce(g.form #> '{req,dates}', '[]')) x), current_date);
$$;

-- Schedulers: submitted to UVU, approved by UVU, sent back, window narrowed, or removed. The approval window is
-- always inside the semester of the guest's likely date; leaving it blank uses the whole semester.
create or replace function public.guest_scheduler_update(p_id uuid, p_status text, p_note text default '', p_start date default null, p_end date default null) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); g guest_requests; sem record;
begin
  if not public.is_scheduler() then return 'err:notscheduler'; end if;
  select * into g from guest_requests where id = p_id;
  if g.id is null then return 'err:missing'; end if;
  select * into sem from semester_bounds(gq_likely(g));
  p_start := greatest(coalesce(p_start, sem.s), sem.s);
  p_end := least(coalesce(p_end, sem.e), sem.e);
  if p_end < p_start then return 'err:window'; end if;
  if p_status = 'submitted' and g.status = 'sent' then perform gq_move(p_id, 'submitted', me);
  elsif p_status = 'approved' and g.status = 'submitted' then
    update guest_requests set window_start = p_start, window_end = p_end where id = p_id;
    perform gq_move(p_id, 'approved', me);
  elsif p_status = 'window' and g.status = 'approved' then
    update guest_requests set window_start = p_start, window_end = p_end where id = p_id;
  elsif p_status = 'removed' and g.status = 'approved' then perform gq_move(p_id, 'removed', me, coalesce(p_note, ''));
  elsif p_status = 'returned' and g.status in ('sent', 'submitted') then
    if trim(coalesce(p_note, '')) = '' then return 'err:note'; end if;
    update guest_requests set note = left(trim(p_note), 4000), returned_from = 'sent' where id = p_id;
    perform gq_move(p_id, 'returned', me, trim(p_note));
  else return 'err:state'; end if;
  return 'ok';
end $$;
grant execute on function public.guest_scheduler_update(uuid, text, text, date, date) to authenticated;

-- The 48-business-hour timer covers guest reviews too, but only ones a president sent (the automatic-emails job calls this).
create or replace function public.request_timeouts() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select event_id, status from event_requests where status in ('review', 'signoff') and now() >= business_add(status_at, 48)
             and (status = 'review' or exists (select 1 from wfa_presidents() e where e = status_by)) loop
    if r.status = 'review' then perform rq_move(r.event_id, 'sent', 'system', 'No objections in 48 hours.');
    else perform rq_publish(r.event_id, 'system', 'No objections in 48 hours.'); end if;
    n := n + 1;
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
