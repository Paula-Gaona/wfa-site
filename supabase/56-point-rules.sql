-- WFA update: automatic point rules. Admins set "give N points to everyone who [joins / RSVPs to an event / checks in at
-- an event / fills out an event's survey] by [deadline]". Everyone who already qualifies gets the points right away, and
-- anyone who qualifies later (up to the deadline) gets them within about 10 minutes (the auto-emails function runs
-- apply_point_rules() every 10 minutes). RSVP rules can take the points back from people who didn't check in once the
-- event ends, and from anyone who cancels their RSVP. Officers and test accounts are skipped (they aren't ranked).
-- Each person earns a rule once. Deleting a rule removes the points it gave.
-- Run once in Supabase -> SQL Editor, after 30-point-awards.sql. Safe to run again.

create table if not exists public.point_rules (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  created_by text not null default public.jwt_email(),
  kind text not null check (kind in ('join', 'rsvp', 'checkin', 'survey')),
  event_id uuid references public.events (id) on delete cascade,
  deadline timestamptz not null,
  points int not null check (points between -1000 and 1000 and points <> 0),
  reason text not null check (char_length(reason) between 1 and 200),
  revoke_noshow boolean not null default false,
  check ((kind = 'join') = (event_id is null))
);
alter table public.point_rules enable row level security;
drop policy if exists "admins manage point rules" on public.point_rules;
create policy "admins manage point rules" on public.point_rules for all using (is_admin()) with check (is_admin());
grant select, insert, update, delete on public.point_rules to authenticated;
grant select, insert, update, delete on public.point_rules to service_role;

-- Which rule an award came from (manual awards have none). One award per person per rule.
alter table public.point_awards add column if not exists rule_id uuid references public.point_rules (id) on delete cascade;
create unique index if not exists point_awards_rule_once on public.point_awards (rule_id, email) where rule_id is not null;

-- Gives (and, for RSVP rules, takes back) the points every rule calls for. Safe to run any number of times.
create or replace function public.apply_point_rules() returns int
language plpgsql security definer set search_path = public as $$
declare r record; added int := 0; n int; cutoff timestamptz;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not is_admin() then raise exception 'Only admins can do that.'; end if;
  for r in select * from point_rules loop
    cutoff := date_trunc('minute', r.deadline) + interval '1 minute';   -- the deadline minute counts ("by 11:59 PM")
    insert into point_awards (email, points, reason, awarded_by, rule_id)
    select q.email, r.points, r.reason, 'automatic rule', r.id from (
      select m.email from members m join auth.users u on u.id = m.id where r.kind = 'join' and u.created_at < cutoff
      union select x.email from rsvps x where r.kind = 'rsvp' and x.event_id = r.event_id and x.created_at < cutoff
      union select x.email from attendance x where r.kind = 'checkin' and x.event_id = r.event_id and x.created_at < cutoff
      union select x.email from event_surveys x where r.kind = 'survey' and x.event_id = r.event_id and x.created_at < cutoff
    ) q
    where not exists (select 1 from access_list al where al.email = q.email)
      and not exists (select 1 from test_accounts ta where ta.email = q.email)
    on conflict do nothing;
    get diagnostics n = row_count; added := added + n;
    if r.kind = 'rsvp' then
      -- A cancelled RSVP loses the points.
      delete from point_awards pa where pa.rule_id = r.id
        and not exists (select 1 from rsvps x where x.event_id = r.event_id and x.email = pa.email);
      -- No-shows lose them once the event is over.
      if r.revoke_noshow and exists (select 1 from events e where e.id = r.event_id
          and ((e.date + coalesce(e.end_time, e.start_time, '23:59')::time) at time zone 'America/Denver') < now()) then
        delete from point_awards pa where pa.rule_id = r.id
          and not exists (select 1 from attendance a where a.event_id = r.event_id and a.email = pa.email);
      end if;
    end if;
  end loop;
  return added;
end $$;
revoke execute on function public.apply_point_rules() from public, anon;
grant execute on function public.apply_point_rules() to authenticated, service_role;
