-- WFA update: a class visit calendar (Officer tools -> Class visits). Each visit has the class, professor, classroom,
-- day and time, and the officer doing it. A visit can be left open until an officer claims it.
-- The auto-emails function reminds the officer the morning of the visit and again two hours before.
-- Run once in Supabase -> SQL Editor, after 115. Safe to run again. Then update the auto-emails function.

create table if not exists public.class_visits (
  id uuid primary key default gen_random_uuid(),
  course text not null,                        -- 'FIN 3100, Principles of Finance'
  professor text not null default '',
  room text not null default '',
  date date not null,
  start_time time not null,
  end_time time,
  notes text not null default '',
  officer text,                                -- the officer's email; null = open, anyone can claim it
  created_by text default public.jwt_email(),
  created_at timestamptz not null default now(),
  day_reminded_at timestamptz,                 -- the morning-of reminder went out
  soon_reminded_at timestamptz                 -- the two-hours-before reminder went out
);
alter table public.class_visits enable row level security;
drop policy if exists "officers manage class visits" on public.class_visits;
create policy "officers manage class visits" on public.class_visits for all using (public.is_officer()) with check (public.is_officer());
grant select, insert, update, delete on public.class_visits to authenticated, service_role;

-- Claim an open visit. Returns 'ok', or 'taken' if someone else got it first.
create or replace function public.claim_class_visit(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); n int;
begin
  if not public.is_officer() then return 'officers'; end if;
  update class_visits set officer = me where id = p_id and officer is null;
  get diagnostics n = row_count;
  return case when n > 0 then 'ok' else 'taken' end;
end $$;
grant execute on function public.claim_class_visit(uuid) to authenticated;
