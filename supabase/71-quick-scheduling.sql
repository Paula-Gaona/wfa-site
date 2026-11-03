-- WFA update: an admin switch for the event checks and balances (Officer tools -> Scheduling, admins only).
-- When it's on ("quick scheduling"):
--   * branch review is skipped: a sent event goes straight to "Confirming with UVU", and
--   * the presidents' sign-off is skipped: once a scheduler confirms it with UVU and sets the final details, it publishes.
-- A scheduler still confirms every event with UVU. Turning it on also moves events already waiting on branch review to
-- the UVU step, and publishes events already waiting on sign-off. Turning it off brings both checks back for new steps.
-- Run once in Supabase -> SQL Editor, after 61-department-scheduling.sql. Safe to run again.

alter table public.settings add column if not exists quick_scheduling boolean not null default false;

create or replace function public.rq_quick() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select s.quick_scheduling from settings s where s.id = 1), false);
$$;
grant execute on function public.rq_quick() to authenticated;

-- Admins turn it on or off.
create or replace function public.set_quick_scheduling(p_on boolean) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); r record;
begin
  if not public.is_admin() then return 'err:notadmin'; end if;
  update settings set quick_scheduling = p_on where id = 1;
  if p_on then
    for r in select event_id from event_requests where status = 'branch' loop
      perform rq_move(r.event_id, 'sent', me, 'Branch review was turned off by an admin.');
    end loop;
    for r in select event_id from event_requests where status = 'signoff' loop
      perform rq_publish(r.event_id, me, 'Published: the presidents'' sign-off was turned off by an admin.');
      update events set published_at = coalesce(published_at, now()) where id = r.event_id;
    end loop;
  end if;
  insert into change_log (text) values ((case when p_on then 'Turned off' else 'Turned back on' end) || ' branch review and the presidents'' sign-off for events');
  return 'ok';
end $$;
grant execute on function public.set_quick_scheduling(boolean) to authenticated;

-- Same as 61, except branch review is skipped while quick scheduling is on.
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
  target := case when rq_quick() then 'sent'
                 when r.status = 'returned' and r.returned_from = 'branch' then 'branch'
                 when r.status = 'returned' and r.returned_from is not null then 'sent'
                 when needs_branch_review(me) then 'branch'
                 else 'sent' end;
  update event_requests set sent_by = coalesce(sent_by, me), sent_at = now(), note = '', returned_from = null,
    branch = coalesce(branch, (select p.branch from officer_profiles p where p.email = me)) where event_id = p_event;
  perform rq_move(p_event, target, me);
  return 'ok';
end $$;
grant execute on function public.save_event_request(uuid, jsonb, boolean) to authenticated;

-- Same as 61, except "send to sign-off" publishes right away while quick scheduling is on.
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
    if rq_quick() then
      perform rq_publish(p_event, me, 'Published by the scheduler (the presidents'' sign-off is turned off).');
      update events set published_at = coalesce(published_at, now()) where id = p_event;
      return 'ok:published';
    end if;
    update event_requests set signoff_note = '' where event_id = p_event;
    perform rq_start_round(p_event, 'signoff', me);
  else return 'err:status'; end if;
  return 'ok';
end $$;
grant execute on function public.scheduler_update(uuid, text, text) to authenticated;
