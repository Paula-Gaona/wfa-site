-- WFA update: event scheduling (UVU requires club events to be approved before they're marketed).
-- Every event except officer meetings goes through these steps before it's published:
--   1. Branch review: drafts made by officers (not presidents, vice presidents, advisors, or admins) go to the
--      president of the officer's branch (all presidents if the branch has none), who approves or sends it back.
--   2. Presidents' review (case competitions, excursions, guest speakers, career fairs): every president approves or
--      requests changes. It moves on once all approve, or automatically after 48 hours with no objection.
--   3. Scheduler: submits it to UVU (or sends it back), then marks it approved once UVU approves.
--   4. Presidents' sign-off: the scheduler sets the final date, times, location, and RSVP timing and sends it to every
--      president. It publishes once all approve, or automatically after 48 hours. A requested change goes back to the
--      scheduler, and the 48 hours restart when they send it again.
-- A president who sent or already approved something counts as approving it, and so does one whose suggested changes
-- were all made. Majority rules after 5 days in a presidents' step, or from its third round of changes. Admins mark who the event schedulers
-- are (only officers can see that), and only schedulers can turn on a draft's coming-soon page.
-- Also: events can open RSVPs at a set time (not just when published), and guests can open a set time or a number of
-- days after members. Files people attach go in a private "event-files" storage folder officers can open.
-- Run once in Supabase -> SQL Editor, after 51. Safe to run again.

-- ---------- Who schedules ----------
create table if not exists public.event_schedulers (
  email text primary key,
  added_at timestamptz not null default now()
);
alter table public.event_schedulers enable row level security;
drop policy if exists "officers see schedulers" on public.event_schedulers;
create policy "officers see schedulers" on public.event_schedulers for select using (public.is_officer());
drop policy if exists "admins add schedulers" on public.event_schedulers;
create policy "admins add schedulers" on public.event_schedulers for insert with check (public.is_admin());
drop policy if exists "admins remove schedulers" on public.event_schedulers;
create policy "admins remove schedulers" on public.event_schedulers for delete using (public.is_admin());
grant select, insert, delete on public.event_schedulers to authenticated;
grant select, insert, update, delete on public.event_schedulers to service_role;

create or replace function public.is_scheduler() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from event_schedulers s join access_list a on a.email = s.email where s.email = public.jwt_email());
$$;
grant execute on function public.is_scheduler() to authenticated;

-- ---------- Who reviews ----------
create or replace function public.wfa_presidents() returns setof text
language sql stable security definer set search_path = public as $$
  select p.email from officer_profiles p join access_list a on a.email = p.email where p.tier = 'president';
$$;
create or replace function public.big_event(p_cat text) returns boolean
language sql immutable as $$ select p_cat in ('case_competition', 'excursion', 'guest_speaker', 'career_fair'); $$;
-- Officers (not presidents, vice presidents, advisors, or admins) need their branch president's approval first.
create or replace function public.needs_branch_review(p_email text) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from officer_profiles p where p.email = p_email and p.tier in ('president', 'vice_president', 'advisor'))
     and not exists (select 1 from access_list a where a.email = p_email and a.role = 'admin');
$$;
-- The presidents of a branch, or every president if the branch has none.
create or replace function public.branch_reviewers(p_branch text) returns setof text
language sql stable security definer set search_path = public as $$
  select e from wfa_presidents() e join officer_profiles p on p.email = e where p.branch = p_branch
  union all
  select e from wfa_presidents() e where not exists (select 1 from wfa_presidents() x join officer_profiles p on p.email = x where p.branch = p_branch);
$$;
grant execute on function public.wfa_presidents(), public.big_event(text), public.needs_branch_review(text), public.branch_reviewers(text) to authenticated;

-- ---------- Requests ----------
create table if not exists public.event_requests (
  event_id uuid primary key references public.events (id) on delete cascade,
  form jsonb not null default '{}',
  status text not null default 'draft',
  note text not null default '',            -- why it was sent back
  sent_by text,
  sent_at timestamptz,
  status_at timestamptz not null default now(),
  status_by text,
  history jsonb not null default '[]',      -- [{at, by, status, note}]
  nudged_at timestamptz,                    -- last time the people it's waiting on were told
  sender_notified_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.event_requests add column if not exists branch text;                              -- for the branch review
alter table public.event_requests add column if not exists votes jsonb not null default '{}';        -- presidents who approved this round
alter table public.event_requests add column if not exists signoff_note text not null default '';    -- a president's requested change
alter table public.event_requests add column if not exists returned_from text;                       -- where a resend goes back to
alter table public.event_requests add column if not exists suggestions jsonb not null default '[]';  -- presidents' suggested changes
alter table public.event_requests add column if not exists objections jsonb not null default '{}';  -- under majority rules
alter table public.event_requests add column if not exists step_kind text;                           -- the presidents' step it's in
alter table public.event_requests add column if not exists step_started_at timestamptz;              -- when that step first started
alter table public.event_requests add column if not exists rounds int not null default 0;            -- times it was sent back in that step
alter table public.event_requests drop constraint if exists event_requests_status_check;
alter table public.event_requests add constraint event_requests_status_check
  check (status in ('draft', 'branch', 'review', 'sent', 'returned', 'submitted', 'approved', 'signoff', 'published'));
alter table public.event_requests enable row level security;
drop policy if exists "officers see requests" on public.event_requests;
create policy "officers see requests" on public.event_requests for select using (public.is_officer());
grant select on public.event_requests to authenticated;
grant select, insert, update, delete on public.event_requests to service_role;

-- Moves a request to a step (and records it).
create or replace function public.rq_move(p_event uuid, p_status text, p_by text, p_note text default '') returns void
language sql security definer set search_path = public as $$
  update event_requests set status = p_status, status_at = now(), status_by = p_by, nudged_at = null,
    votes = case when p_status in ('review', 'signoff') then '{}'::jsonb else votes end,
    objections = case when p_status in ('review', 'signoff') then '{}'::jsonb else objections end,
    history = history || jsonb_build_array(jsonb_build_object('at', now(), 'by', p_by, 'status', p_status, 'note', coalesce(p_note, '')))
    where event_id = p_event;
$$;
-- Publishes the event (the only way an event that needs scheduling gets published).
create or replace function public.rq_publish(p_event uuid, p_by text, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
begin
  perform rq_move(p_event, 'published', p_by, p_note);
  update events set draft = false where id = p_event;
end $$;
-- Majority rules: after 5 days in a presidents' step, or from the third round of changes on.
create or replace function public.rq_majority(r event_requests) returns boolean
language sql stable as $$ select coalesce(r.rounds, 0) >= 2 or r.step_started_at < now() - interval '5 days'; $$;
-- Moves on once every president has approved (or, under majority rules, at least half).
create or replace function public.rq_check_round(p_event uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r event_requests; n int; yes int; note text := '';
begin
  select * into r from event_requests where event_id = p_event;
  if r.status not in ('review', 'signoff') then return; end if;
  select count(*), count(*) filter (where r.votes ? e) into n, yes from wfa_presidents() e;
  if yes < n then
    if not rq_majority(r) or yes * 2 < n then return; end if;
    note := format('Passed by majority (%s of %s presidents approved).', yes, n);
  else note := 'Every president approved.'; end if;
  if r.status = 'review' then perform rq_move(p_event, 'sent', 'system', note);
  else perform rq_publish(p_event, 'system', note); end if;
end $$;
-- Does the event or form now have the value a president suggested?
create or replace function public.rq_change_met(ev events, form jsonb, c jsonb) returns boolean
language sql stable as $$
  select case when c->>'target' = 'event' and c->>'field' in ('rsvp_opens', 'guest_rsvp_opens')
                then (to_jsonb(ev)->>(c->>'field'))::timestamptz is not distinct from nullif(c->>'to', '')::timestamptz
              when c->>'target' = 'event' then coalesce(to_jsonb(ev)->>(c->>'field'), '') = coalesce(c->>'to', '')
              else coalesce(form->>(c->>'field'), '') = coalesce(c->>'to', '') end;
$$;
-- Starts a presidents' round. A president moving it along counts as approving, and so does a president whose
-- suggested changes were all made.
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
      if jsonb_array_length(coalesce(s->'changes', '[]')) > 0
         and not exists (select 1 from jsonb_array_elements(s->'changes') c where not rq_change_met(ev, r.form, c)) then
        v := v || jsonb_build_object(s->>'by', now()); s := s || '{"state": "met"}';
      else s := s || '{"state": "answered"}'; end if;
    end if;
    out := out || jsonb_build_array(s);
  end loop;
  update event_requests set votes = v, suggestions = out where event_id = p_event;
  perform rq_check_round(p_event);
end $$;

-- Save the form, and optionally send it on. The sender can't change it once it's moving.
create or replace function public.save_event_request(p_event uuid, p_form jsonb, p_send boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); r event_requests; cat text; target text;
begin
  if not public.is_officer() then return 'err:notofficer'; end if;
  select e.cat into cat from events e where e.id = p_event;
  if cat is null or cat = 'officer_meeting' then return 'err:event'; end if;
  select * into r from event_requests where event_id = p_event;
  if r.status is not null and r.status not in ('draft', 'returned') then return 'err:locked'; end if;
  insert into event_requests (event_id, form) values (p_event, coalesce(p_form, '{}'))
    on conflict (event_id) do update set form = excluded.form;
  if not p_send then return 'ok'; end if;
  -- A resend goes back to the step that sent it back; a first send starts at the beginning.
  target := case when r.status = 'returned' and r.returned_from in ('branch', 'review') then r.returned_from
                 when r.status = 'returned' and r.returned_from is not null then 'sent'
                 when needs_branch_review(me) then 'branch'
                 when big_event(cat) then 'review' else 'sent' end;
  update event_requests set sent_by = coalesce(sent_by, me), sent_at = now(), note = '', returned_from = null,
    branch = coalesce(branch, (select p.branch from officer_profiles p where p.email = me)) where event_id = p_event;
  if target = 'review' then perform rq_start_round(p_event, 'review', me);
  else perform rq_move(p_event, target, me); end if;
  return 'ok';
end $$;
grant execute on function public.save_event_request(uuid, jsonb, boolean) to authenticated;

-- Step 1: the branch president approves (it moves on) or sends it back with notes.
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
  select e.cat into cat from events e where e.id = p_event;
  if big_event(cat) then perform rq_start_round(p_event, 'review', me);
  else perform rq_move(p_event, 'sent', me, 'Approved by the branch president.'); end if;
  return 'ok';
end $$;
grant execute on function public.branch_review(uuid, boolean, text) to authenticated;

-- Steps 2 and 4: a president approves, or requests changes (a note and/or suggested values:
-- [{target: 'event'|'form', field, label, from, to, why}]). Under majority rules a request for changes is an
-- objection: it only sends the event back once more than half the presidents object.
drop function if exists public.president_vote(uuid, boolean, text);
create or replace function public.president_vote(p_event uuid, p_ok boolean, p_note text default '', p_changes jsonb default '[]') returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); r event_requests; n int; no int;
begin
  select * into r from event_requests where event_id = p_event;
  if r.status not in ('review', 'signoff') then return 'err:state'; end if;
  if not exists (select 1 from wfa_presidents() e where e = me) then return 'err:notpresident'; end if;
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
      'note', trim(coalesce(p_note, '')), 'changes', coalesce(p_changes, '[]'), 'replies', '{}'::jsonb))
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
  if r.status = 'review' then
    update event_requests set note = left(trim(coalesce(p_note, '')), 4000), returned_from = 'review' where event_id = p_event;
    perform rq_move(p_event, 'returned', me, coalesce(nullif(trim(p_note), ''), 'Suggested changes.'));
  else
    update event_requests set signoff_note = left(coalesce(nullif(trim(p_note), ''), 'See the suggested changes.'), 4000) where event_id = p_event;
    perform rq_move(p_event, 'approved', me, 'Changes requested: ' || coalesce(nullif(trim(p_note), ''), 'see the suggestions'));
  end if;
  return 'ok';
end $$;
grant execute on function public.president_vote(uuid, boolean, text, jsonb) to authenticated;

-- Whoever is fixing it (the sender after a review, or a scheduler after sign-off) explains suggestions they didn't make:
-- p_replies = {"president@uvu.edu": {"field": "reason", ...}}.
create or replace function public.reply_suggestions(p_event uuid, p_replies jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); r event_requests; s jsonb; out jsonb := '[]';
begin
  select * into r from event_requests where event_id = p_event;
  if not (r.sent_by = me or public.is_scheduler()) then return 'err:notallowed'; end if;
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

-- Step 3 (and starting step 4): schedulers send it back, mark it submitted or approved by UVU, or send the finalized
-- event to the presidents.
create or replace function public.scheduler_update(p_event uuid, p_status text, p_note text default '') returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); cur text;
begin
  if not public.is_scheduler() then return 'err:notscheduler'; end if;
  select status into cur from event_requests where event_id = p_event;
  if cur is null then return 'err:missing'; end if;
  if p_status = 'returned' then
    if cur not in ('sent', 'submitted', 'approved') then return 'err:state'; end if;
    if trim(coalesce(p_note, '')) = '' then return 'err:note'; end if;
    update event_requests set note = left(trim(p_note), 4000), returned_from = 'sent' where event_id = p_event;
    perform rq_move(p_event, 'returned', me, trim(p_note));
  elsif p_status = 'submitted' then
    if cur <> 'sent' then return 'err:state'; end if;
    perform rq_move(p_event, 'submitted', me);
  elsif p_status = 'approved' then
    if cur <> 'submitted' then return 'err:state'; end if;
    perform rq_move(p_event, 'approved', me);
  elsif p_status = 'signoff' then
    if cur <> 'approved' then return 'err:state'; end if;
    update event_requests set signoff_note = '' where event_id = p_event;
    perform rq_start_round(p_event, 'signoff', me);
  else return 'err:status'; end if;
  return 'ok';
end $$;
grant execute on function public.scheduler_update(uuid, text, text) to authenticated;

-- Presidents' steps that have waited 48 hours move on by themselves (the automatic-emails job calls this). Any
-- objection that would stop it has already sent it back, so whatever is still waiting passes.
create or replace function public.request_timeouts() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select event_id, status from event_requests where status in ('review', 'signoff') and status_at < now() - interval '48 hours' loop
    if r.status = 'review' then perform rq_move(r.event_id, 'sent', 'system', 'No objections in 48 hours.');
    else perform rq_publish(r.event_id, 'system', 'No objections in 48 hours.'); end if;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.request_timeouts() from public, anon, authenticated;
grant execute on function public.request_timeouts() to service_role;
revoke execute on function public.rq_move(uuid, text, text, text), public.rq_publish(uuid, text, text), public.rq_check_round(uuid),
  public.rq_start_round(uuid, text, text) from public, anon, authenticated;

-- Drafts with a coming-soon page were already sent to the clubs office by hand: count them as submitted to UVU.
insert into public.event_requests (event_id, form, status, status_at, history)
  select e.id, '{"legacy": true}'::jsonb, 'submitted', now(),
    jsonb_build_array(jsonb_build_object('at', now(), 'by', 'system', 'status', 'submitted', 'note', 'Sent to the clubs office before scheduling requests were on the site.'))
  from public.events e where e.draft and e.coming_soon and e.cat <> 'officer_meeting'
  on conflict (event_id) do nothing;

-- ---------- Publishing goes through the steps ----------
create or replace function public.guard_event_publish() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or new.draft or new.cat = 'officer_meeting' then return new; end if;
  if tg_op = 'UPDATE' and not old.draft then return new; end if;     -- already published: normal edits are fine
  if not exists (select 1 from event_requests r where r.event_id = new.id and r.status = 'published') then
    raise exception 'This event is published after UVU approves it and the presidents sign off. Send it through Scheduling.';
  end if;
  return new;
end $$;
drop trigger if exists guard_event_publish on public.events;
create trigger guard_event_publish before insert or update on public.events
  for each row execute function public.guard_event_publish();

-- Coming-soon pages: schedulers only.
create or replace function public.guard_coming_soon() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_scheduler() or auth.uid() is null then return new; end if;
  if tg_op = 'INSERT' then new.coming_soon := false; new.soon_desc := '';
  else new.coming_soon := old.coming_soon; new.soon_desc := old.soon_desc; end if;
  return new;
end $$;

-- ---------- RSVP timing ----------
alter table public.events add column if not exists rsvp_opens timestamptz;       -- null = as soon as it's published
alter table public.events add column if not exists guest_rsvp_delay int;         -- guests: this many days after members
alter table public.events add column if not exists published_at timestamptz;
create or replace function public.event_rsvp_times() returns trigger
language plpgsql as $$
begin
  if not new.draft and (tg_op = 'INSERT' or old.draft) then new.published_at := now(); end if;
  if new.guest_rsvp_delay is not null then
    new.guest_rsvp_opens := case when new.draft then null
      else coalesce(new.rsvp_opens, new.published_at, now()) + make_interval(days => new.guest_rsvp_delay) end;
  end if;
  -- Guests never open before members.
  if new.rsvp_opens is not null and (new.guest_rsvp_opens is null or new.guest_rsvp_opens < new.rsvp_opens) then
    new.guest_rsvp_opens := new.rsvp_opens;
  end if;
  return new;
end $$;
drop trigger if exists event_rsvp_times on public.events;
create trigger event_rsvp_times before insert or update on public.events for each row execute function public.event_rsvp_times();

-- No RSVPs to drafts, or before RSVPs open.
create or replace function public.no_draft_rsvps() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from events e where e.id = new.event_id and e.draft) then
    raise exception 'RSVPs open when the event is published.';
  end if;
  if exists (select 1 from events e where e.id = new.event_id and e.rsvp_opens > now()) then
    raise exception 'RSVPs for this event aren''t open yet.';
  end if;
  return new;
end $$;

-- ---------- Attached files ----------
insert into storage.buckets (id, name, public) values ('event-files', 'event-files', false) on conflict (id) do nothing;
drop policy if exists "officers upload event files" on storage.objects;
create policy "officers upload event files" on storage.objects for insert to authenticated
  with check (bucket_id = 'event-files' and public.is_officer());
drop policy if exists "officers read event files" on storage.objects;
create policy "officers read event files" on storage.objects for select to authenticated
  using (bucket_id = 'event-files' and public.is_officer());
drop policy if exists "officers delete event files" on storage.objects;
create policy "officers delete event files" on storage.objects for delete to authenticated
  using (bucket_id = 'event-files' and public.is_officer());
