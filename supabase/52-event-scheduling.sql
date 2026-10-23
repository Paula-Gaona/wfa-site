-- WFA update: event scheduling requests (UVU requires club events to be approved before they're marketed).
--   * Admins mark officers (faculty advisors and admins included) as event schedulers. Only officers can see who is one.
--   * Every event except officer meetings needs a scheduling request: the officer making it fills out the form and
--     sends it to the schedulers. A scheduler submits it to UVU (marks it "submitted for approval") or sends it back
--     with notes, and marks it approved once UVU approves. Only a scheduler can publish it, and only once approved.
--   * Only schedulers can turn on a draft's coming-soon page.
--   * Files people attach (flyers, custom layout pictures) go in a private "event-files" storage folder officers can open.
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

-- ---------- Requests ----------
create table if not exists public.event_requests (
  event_id uuid primary key references public.events (id) on delete cascade,
  form jsonb not null default '{}',
  status text not null default 'draft' check (status in ('draft', 'sent', 'returned', 'submitted', 'approved')),
  note text not null default '',            -- the scheduler's notes when they send it back
  sent_by text,
  sent_at timestamptz,
  status_at timestamptz not null default now(),
  status_by text,
  history jsonb not null default '[]',      -- [{at, by, status, note}]
  nudged_at timestamptz,                    -- last time the schedulers were told about it
  sender_notified_at timestamptz,           -- last time the sender was told about a status change
  created_at timestamptz not null default now()
);
alter table public.event_requests enable row level security;
drop policy if exists "officers see requests" on public.event_requests;
create policy "officers see requests" on public.event_requests for select using (public.is_officer());
grant select on public.event_requests to authenticated;
grant select, insert, update, delete on public.event_requests to service_role;

-- Save the form (and optionally send it to the schedulers). The sender can't change it while a scheduler has it.
create or replace function public.save_event_request(p_event uuid, p_form jsonb, p_send boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); cur text;
begin
  if not public.is_officer() then return 'err:notofficer'; end if;
  if not exists (select 1 from events e where e.id = p_event and e.cat <> 'officer_meeting') then return 'err:event'; end if;
  select status into cur from event_requests where event_id = p_event;
  if cur in ('sent', 'submitted', 'approved') then return 'err:locked'; end if;
  insert into event_requests (event_id, form) values (p_event, coalesce(p_form, '{}'))
    on conflict (event_id) do update set form = excluded.form;
  if p_send then
    update event_requests set status = 'sent', sent_by = me, sent_at = now(), status_at = now(), status_by = me,
      history = history || jsonb_build_array(jsonb_build_object('at', now(), 'by', me, 'status', 'sent', 'note', ''))
      where event_id = p_event;
  end if;
  return 'ok';
end $$;
grant execute on function public.save_event_request(uuid, jsonb, boolean) to authenticated;

-- Schedulers: send it back with notes, mark it submitted to UVU, or mark it approved.
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
  elsif p_status = 'submitted' then
    if cur <> 'sent' then return 'err:state'; end if;
  elsif p_status = 'approved' then
    if cur <> 'submitted' then return 'err:state'; end if;
  else return 'err:status'; end if;
  update event_requests set status = p_status, status_at = now(), status_by = me,
    note = case when p_status = 'returned' then left(trim(p_note), 4000) else note end,
    history = history || jsonb_build_array(jsonb_build_object('at', now(), 'by', me, 'status', p_status, 'note', coalesce(trim(p_note), '')))
    where event_id = p_event;
  return 'ok';
end $$;
grant execute on function public.scheduler_update(uuid, text, text) to authenticated;

-- ---------- Publishing needs UVU approval and a scheduler ----------
create or replace function public.guard_event_publish() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or new.draft or new.cat = 'officer_meeting' then return new; end if;
  if tg_op = 'UPDATE' and not old.draft then return new; end if;     -- already published: normal edits are fine
  if not exists (select 1 from event_requests r where r.event_id = new.id and r.status = 'approved') then
    raise exception 'This event needs UVU approval before it can be published. Send it to the scheduler first.';
  end if;
  if not public.is_scheduler() then
    raise exception 'Only event schedulers can publish events.';
  end if;
  return new;
end $$;
drop trigger if exists guard_event_publish on public.events;
create trigger guard_event_publish before insert or update on public.events
  for each row execute function public.guard_event_publish();

-- Coming-soon pages: schedulers only (was: anyone who can publish).
create or replace function public.guard_coming_soon() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_scheduler() or auth.uid() is null then return new; end if;
  if tg_op = 'INSERT' then new.coming_soon := false; new.soon_desc := '';
  else new.coming_soon := old.coming_soon; new.soon_desc := old.soon_desc; end if;
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
