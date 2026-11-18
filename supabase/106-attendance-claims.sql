-- WFA update: "I was there" requests. For a week after an event, a member who forgot to check in can ask to be added.
-- Nothing changes until an officer approves it (Officer tools -> Attendance): approving checks them in, with the
-- points; denying tells them it wasn't approved.
-- Run once in Supabase -> SQL Editor, after 105. Safe to run again.

create table if not exists public.attendance_claims (
  event_id uuid not null references public.events (id) on delete cascade,
  email text not null default public.jwt_email(),
  note text not null default '' check (char_length(note) <= 300),
  status text not null default 'pending' check (status in ('pending', 'denied')),
  created_at timestamptz not null default now(),
  reviewed_by text,
  reviewed_at timestamptz,
  primary key (event_id, email)
);
alter table public.attendance_claims enable row level security;
drop policy if exists "own or officers read attendance claims" on public.attendance_claims;
create policy "own or officers read attendance claims" on public.attendance_claims for select using (email = public.jwt_email() or public.is_officer());
grant select on public.attendance_claims to authenticated;
grant select, insert, update, delete on public.attendance_claims to service_role;

-- A member asks to be added. Returns 'ok' or why not.
create or replace function public.claim_attendance(p_event uuid, p_note text) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); e events; ends timestamptz;
begin
  if auth.uid() is null or me is null then return 'signin'; end if;
  select * into e from events where id = p_event;
  if e.id is null or e.draft or e.test <> public.is_test() or e.cat = 'officer_meeting'
     or coalesce(e.host, '') <> '' or e.reg_mode = 'link' then return 'missing'; end if;
  ends := (e.date + e.end_time) at time zone 'America/Denver';
  if now() < ends then return 'notover'; end if;
  if now() > ends + interval '7 days' then return 'late'; end if;
  if exists (select 1 from attendance where event_id = p_event and email = me) then return 'here'; end if;
  insert into attendance_claims (event_id, email, note) values (p_event, me, left(trim(coalesce(p_note, '')), 300))
  on conflict (event_id, email) do nothing;
  return 'ok';
end $$;
grant execute on function public.claim_attendance(uuid, text) to authenticated;

-- Officers approve (check them in) or deny a request.
create or replace function public.review_attendance_claim(p_event uuid, p_email text, p_ok boolean) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_officer() then return 'officers'; end if;
  if not exists (select 1 from attendance_claims where event_id = p_event and email = p_email) then return 'missing'; end if;
  if p_ok then
    insert into attendance (event_id, email) values (p_event, p_email) on conflict do nothing;
    delete from attendance_claims where event_id = p_event and email = p_email;
  else
    update attendance_claims set status = 'denied', reviewed_by = public.jwt_email(), reviewed_at = now()
    where event_id = p_event and email = p_email;
  end if;
  return 'ok';
end $$;
grant execute on function public.review_attendance_claim(uuid, text, boolean) to authenticated;
