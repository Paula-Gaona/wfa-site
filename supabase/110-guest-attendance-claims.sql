-- WFA update: guests can send "I was there" requests too (no account needed): name, email, and one thing they learned.
-- An officer approves it like a member's; approving adds a guest check-in (no points; they move to the account if the
-- guest joins later with that email).
-- Run once in Supabase -> SQL Editor, after 109. Safe to run again.

alter table public.attendance_claims add column if not exists guest boolean not null default false;
alter table public.attendance_claims add column if not exists first text not null default '';
alter table public.attendance_claims add column if not exists last text not null default '';
alter table public.attendance_claims add column if not exists uvid text not null default '';

drop function if exists public.guest_claim_attendance(uuid, text, text, text, text);
create or replace function public.guest_claim_attendance(p_event uuid, p_first text, p_last text, p_email text, p_note text, p_uvid text default '') returns text
language plpgsql security definer set search_path = public as $$
declare e events; ends timestamptz; em text := lower(trim(coalesce(p_email, '')));
  u text := regexp_replace(coalesce(p_uvid, ''), '\D', '', 'g');
begin
  if trim(coalesce(p_first, '')) = '' or trim(coalesce(p_last, '')) = '' then return 'name'; end if;
  if em !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or char_length(em) > 200 then return 'email'; end if;
  if char_length(trim(coalesce(p_note, ''))) < 20 then return 'note'; end if;
  if u <> '' and u !~ '^\d{8}$' then return 'uvid'; end if;
  select * into e from events where id = p_event;
  if e.id is null or e.draft or e.test or e.members_only or e.cat = 'officer_meeting'
     or coalesce(e.host, '') <> '' or e.reg_mode = 'link' then return 'missing'; end if;
  ends := (e.date + e.end_time) at time zone 'America/Denver';
  if now() < ends then return 'notover'; end if;
  if now() > ends + interval '7 days' then return 'late'; end if;
  if exists (select 1 from members m where m.email = em) then return 'member'; end if;
  if exists (select 1 from guest_checkins where event_id = p_event and email = em) then return 'here'; end if;
  insert into attendance_claims (event_id, email, note, guest, first, last, uvid)
  values (p_event, em, left(trim(p_note), 300), true, left(trim(p_first), 60), left(trim(p_last), 60), u)
  on conflict (event_id, email) do nothing;
  return 'ok';
end $$;
grant execute on function public.guest_claim_attendance(uuid, text, text, text, text, text) to anon, authenticated;

-- Approving a guest's request adds a guest check-in; a member's, an attendance row.
create or replace function public.review_attendance_claim(p_event uuid, p_email text, p_ok boolean) returns text
language plpgsql security definer set search_path = public as $$
declare c attendance_claims;
begin
  if not public.is_officer() then return 'officers'; end if;
  select * into c from attendance_claims where event_id = p_event and email = p_email;
  if c.email is null then return 'missing'; end if;
  if p_ok then
    if c.guest then
      insert into guest_checkins (event_id, first, last, email) values (p_event, c.first, c.last, c.email)
      on conflict (event_id, email) do nothing;
    else
      insert into attendance (event_id, email) values (p_event, p_email) on conflict do nothing;
    end if;
    delete from attendance_claims where event_id = p_event and email = p_email;
  else
    update attendance_claims set status = 'denied', reviewed_by = public.jwt_email(), reviewed_at = now()
    where event_id = p_event and email = p_email;
  end if;
  return 'ok';
end $$;
grant execute on function public.review_attendance_claim(uuid, text, boolean) to authenticated;
