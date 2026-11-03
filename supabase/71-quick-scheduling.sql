-- WFA update: an admin switch for the event checks and balances (Officer tools -> Scheduling, admins only).
-- When it's on ("quick scheduling"), events an ADMIN sends skip the presidents' sign-off: once a scheduler confirms the
-- event with UVU and sets the final details, it publishes. (Admins already skip branch review.) Every other officer's
-- events still go through branch review and sign-off as usual. Turning it on also publishes admins' events already
-- waiting on sign-off. Run once in Supabase -> SQL Editor, after 61-department-scheduling.sql. Safe to run again.

alter table public.settings add column if not exists quick_scheduling boolean not null default false;

create or replace function public.rq_quick() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select s.quick_scheduling from settings s where s.id = 1), false);
$$;
grant execute on function public.rq_quick() to authenticated;

-- Does this request skip sign-off? Only while quick scheduling is on, and only when an admin sent it.
create or replace function public.rq_quick_for(r event_requests) returns boolean
language sql stable security definer set search_path = public as $$
  select rq_quick() and exists (select 1 from access_list a where a.email = r.sent_by and a.role = 'admin');
$$;
grant execute on function public.rq_quick_for(event_requests) to authenticated;

-- Admins turn it on or off.
create or replace function public.set_quick_scheduling(p_on boolean) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); r record;
begin
  if not public.is_admin() then return 'err:notadmin'; end if;
  update settings set quick_scheduling = p_on where id = 1;
  if p_on then
    for r in select q.event_id from event_requests q where q.status = 'signoff' and rq_quick_for(q) loop
      perform rq_publish(r.event_id, me, 'Published: quick scheduling was turned on for admins'' events.');
      update events set published_at = coalesce(published_at, now()) where id = r.event_id;
    end loop;
  end if;
  insert into change_log (text) values ('Turned quick scheduling ' || case when p_on then 'on' else 'off' end || ' (admins'' events skip the presidents'' sign-off)');
  return 'ok';
end $$;
grant execute on function public.set_quick_scheduling(boolean) to authenticated;

-- Same as 61, except "send to sign-off" publishes right away for an admin's event while quick scheduling is on.
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
    if rq_quick_for(r) then
      perform rq_publish(p_event, me, 'Published by the scheduler (quick scheduling: an admin''s event skips sign-off).');
      update events set published_at = coalesce(published_at, now()) where id = p_event;
      return 'ok:published';
    end if;
    update event_requests set signoff_note = '' where event_id = p_event;
    perform rq_start_round(p_event, 'signoff', me);
  else return 'err:status'; end if;
  return 'ok';
end $$;
grant execute on function public.scheduler_update(uuid, text, text) to authenticated;
