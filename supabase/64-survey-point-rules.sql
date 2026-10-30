-- WFA update: automatic point rules can reward answering a survey from the survey builder by a deadline (for
-- example, +5 bonus points for answering within the first two days). Set it up in Admin -> Award points, the same
-- way as the other rules. Run once in Supabase -> SQL Editor, after 63-survey-builder.sql. Safe to run again.

alter table public.point_rules add column if not exists survey_id uuid references public.surveys (id) on delete cascade;
alter table public.point_rules drop constraint if exists point_rules_kind_check;
alter table public.point_rules add constraint point_rules_kind_check check (kind in ('join', 'rsvp', 'checkin', 'survey', 'form'));
-- Which thing each kind points at: nothing for joining, an event for event rules, a survey for 'form'.
alter table public.point_rules drop constraint if exists point_rules_check;
alter table public.point_rules drop constraint if exists point_rules_target;
alter table public.point_rules add constraint point_rules_target check (
  (kind = 'join' and event_id is null and survey_id is null)
  or (kind = 'form' and event_id is null and survey_id is not null)
  or (kind in ('rsvp', 'checkin', 'survey') and event_id is not null and survey_id is null));

-- Same as 56-point-rules.sql, plus survey-builder answers (counted from when they first answered).
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
      union select x.email from survey_responses x where r.kind = 'form' and x.survey_id = r.survey_id and x.created_at < cutoff
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
