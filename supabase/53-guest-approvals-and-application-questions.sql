-- WFA update: two things.
-- 1. External guest pre-approval. Officers can get a speaker (or judge, panelist...) approved by UVU before the event
--    itself is planned, using estimates. It goes through a lighter review: branch review for regular officers, then
--    one president other than the sender (moves on automatically after 48 business hours), then a scheduler submits
--    it to UVU and marks it approved. The approval window is the semester of the guest's estimated date (Spring
--    Jan 1-Apr 30, Summer May 1-Jul 31, Fall Aug 1-Dec 31); the scheduler can narrow it if UVU gives a shorter one. Approved guests can be picked on an
--    event's scheduling request. Nothing here goes on the calendar.
-- 2. Admins can edit the officer application's questions. Answers are saved with the question text they answered.
-- Run once in Supabase -> SQL Editor, after 52. Safe to run again.

-- ---------- Application questions ----------
alter table public.app_settings add column if not exists questions jsonb;                 -- null = the default questions
alter table public.applications add column if not exists answers jsonb not null default '[]';   -- [{id, label, value}]
alter table public.applications alter column why set default '';
alter table public.applications alter column ideas set default '';

-- ---------- External guest approvals ----------
create table if not exists public.guest_requests (
  id uuid primary key default gen_random_uuid(),
  form jsonb not null default '{}',
  status text not null default 'draft'
    check (status in ('draft', 'branch', 'review', 'sent', 'returned', 'submitted', 'approved', 'removed')),
  note text not null default '',
  sent_by text not null default public.jwt_email(),
  branch text,
  votes jsonb not null default '{}',
  status_at timestamptz not null default now(),
  status_by text,
  returned_from text,
  history jsonb not null default '[]',
  nudged_at timestamptz,
  window_start date,          -- UVU's approval window, if they give one
  window_end date,
  created_at timestamptz not null default now()
);
alter table public.guest_requests enable row level security;
drop policy if exists "officers see guest requests" on public.guest_requests;
create policy "officers see guest requests" on public.guest_requests for select using (public.is_officer());
grant select on public.guest_requests to authenticated;
grant select, insert, update, delete on public.guest_requests to service_role;

create or replace function public.gq_move(p_id uuid, p_status text, p_by text, p_note text default '') returns void
language sql security definer set search_path = public as $$
  update guest_requests set status = p_status, status_at = now(), status_by = p_by, nudged_at = null,
    votes = case when p_status = 'review' then '{}'::jsonb else votes end,
    history = history || jsonb_build_array(jsonb_build_object('at', now(), 'by', p_by, 'status', p_status, 'note', coalesce(p_note, '')))
    where id = p_id;
$$;
-- The lighter presidents' step: one president other than the sender. If there isn't one, it goes to the scheduler.
create or replace function public.gq_to_review(p_id uuid, p_by text) returns void
language plpgsql security definer set search_path = public as $$
declare sender text;
begin
  select sent_by into sender from guest_requests where id = p_id;
  if exists (select 1 from wfa_presidents() e where e <> sender) then perform gq_move(p_id, 'review', p_by);
  else perform gq_move(p_id, 'sent', p_by, 'No other president to review it.'); end if;
end $$;
revoke execute on function public.gq_move(uuid, text, text, text), public.gq_to_review(uuid, text) from public, anon, authenticated;

-- Save the form (p_id null = a new one), and optionally send it. Returns the id, or err:...
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
    if r.status not in ('draft', 'returned') then return 'err:locked'; end if;
    if r.sent_by <> me and not public.is_admin() then return 'err:notyours'; end if;
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

-- Branch review (regular officers' requests): approve it on, or send it back with notes.
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
  perform gq_to_review(p_id, me);
  return 'ok';
end $$;
grant execute on function public.guest_branch_review(uuid, boolean, text) to authenticated;

-- One president other than the sender approves it (it goes to the schedulers) or sends it back.
create or replace function public.guest_vote(p_id uuid, p_ok boolean, p_note text default '') returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); r guest_requests;
begin
  select * into r from guest_requests where id = p_id;
  if r.status is distinct from 'review' then return 'err:state'; end if;
  if me = r.sent_by or not exists (select 1 from wfa_presidents() e where e = me) then return 'err:notpresident'; end if;
  if not p_ok then
    if trim(coalesce(p_note, '')) = '' then return 'err:note'; end if;
    update guest_requests set note = left(trim(p_note), 4000), returned_from = 'review' where id = p_id;
    perform gq_move(p_id, 'returned', me, trim(p_note)); return 'ok';
  end if;
  perform gq_move(p_id, 'sent', me, 'Approved by a president.');
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

-- Schedulers: submitted to UVU, approved by UVU, sent back, window narrowed, or removed. The approval window is
-- always inside the semester of the guest's estimated date; leaving it blank uses the whole semester.
create or replace function public.guest_scheduler_update(p_id uuid, p_status text, p_note text default '', p_start date default null, p_end date default null) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); cur text; est date; sem record;
begin
  if not public.is_scheduler() then return 'err:notscheduler'; end if;
  select status, coalesce(nullif(form->>'estFrom', '')::date, current_date) into cur, est from guest_requests where id = p_id;
  if cur is null then return 'err:missing'; end if;
  select * into sem from semester_bounds(est);
  p_start := greatest(coalesce(p_start, sem.s), sem.s);
  p_end := least(coalesce(p_end, sem.e), sem.e);
  if p_end < p_start then return 'err:window'; end if;
  if p_status = 'submitted' and cur = 'sent' then perform gq_move(p_id, 'submitted', me);
  elsif p_status = 'approved' and cur = 'submitted' then
    update guest_requests set window_start = p_start, window_end = p_end where id = p_id;
    perform gq_move(p_id, 'approved', me);
  elsif p_status = 'window' and cur = 'approved' then
    update guest_requests set window_start = p_start, window_end = p_end where id = p_id;
  elsif p_status = 'removed' and cur = 'approved' then perform gq_move(p_id, 'removed', me, coalesce(p_note, ''));
  elsif p_status = 'returned' and cur in ('sent', 'submitted') then
    if trim(coalesce(p_note, '')) = '' then return 'err:note'; end if;
    update guest_requests set note = left(trim(p_note), 4000), returned_from = 'sent' where id = p_id;
    perform gq_move(p_id, 'returned', me, trim(p_note));
  else return 'err:state'; end if;
  return 'ok';
end $$;
grant execute on function public.guest_scheduler_update(uuid, text, text, date, date) to authenticated;

-- The 48-business-hour timer now covers guest reviews too (the automatic-emails job calls this).
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
  for r in select id from guest_requests where status = 'review' and now() >= business_add(status_at, 48) loop
    perform gq_move(r.id, 'sent', 'system', 'No objections in 48 hours.');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.request_timeouts() from public, anon, authenticated;
grant execute on function public.request_timeouts() to service_role;
