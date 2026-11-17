-- WFA update: automatic point rules can have an optional start as well as the deadline, so a rule can reward doing
-- something between two times (like "RSVP in the first 2 days after RSVPs open"). No start means anytime before the
-- deadline, the same as before. The start counts from that minute.
-- Run once in Supabase -> SQL Editor, after 86-edit-point-rules.sql. Safe to run again.

alter table public.point_rules add column if not exists starts_at timestamptz;
alter table public.point_rules drop constraint if exists point_rules_start_before_deadline;
alter table public.point_rules add constraint point_rules_start_before_deadline check (starts_at is null or starts_at < deadline);

-- Who qualifies for a rule right now: did it after the start (if any) and through the deadline minute.
create or replace function public.rule_qualifiers(r point_rules) returns setof text
language sql stable security definer set search_path = public as $$
  select q.email from (
    select m.email, u.created_at as at from members m join auth.users u on u.id = m.id where r.kind = 'join'
    union all select x.email, x.created_at from rsvps x where r.kind = 'rsvp' and x.event_id = r.event_id
    union all select x.email, x.created_at from attendance x where r.kind = 'checkin' and x.event_id = r.event_id
    union all select x.email, x.created_at from event_surveys x where r.kind = 'survey' and x.event_id = r.event_id
    union all select x.email, x.created_at from survey_responses x where r.kind = 'form' and x.survey_id = r.survey_id
  ) q
  where q.at < date_trunc('minute', r.deadline) + interval '1 minute'
    and (r.starts_at is null or q.at >= date_trunc('minute', r.starts_at))
  group by q.email
$$;
revoke execute on function public.rule_qualifiers(point_rules) from public, anon;

-- Same as 64-survey-point-rules.sql, but who qualifies comes from rule_qualifiers (so the start counts).
create or replace function public.apply_point_rules() returns int
language plpgsql security definer set search_path = public as $$
declare r point_rules; added int := 0; n int;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not is_admin() then raise exception 'Only admins can do that.'; end if;
  for r in select * from point_rules loop
    insert into point_awards (email, points, reason, awarded_by, rule_id)
    select q.email, r.points, r.reason, 'automatic rule', r.id from public.rule_qualifiers(r) as q(email)
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

-- Editing a rule, now with the start. Changing the start or deadline gives or takes points to match.
drop function if exists public.edit_point_rule(uuid, text, uuid, uuid, timestamptz, int, text, boolean);
create or replace function public.edit_point_rule(p_id uuid, p_kind text, p_event uuid, p_survey uuid, p_deadline timestamptz,
  p_points int, p_reason text, p_noshow boolean, p_starts timestamptz default null) returns int
language plpgsql security definer set search_path = public as $$
declare old point_rules; r point_rules;
begin
  if not public.is_admin() then raise exception 'Only admins can do that.'; end if;
  select * into old from point_rules where id = p_id;
  if old.id is null then raise exception 'That rule doesn''t exist anymore.'; end if;
  update point_rules set kind = p_kind, event_id = p_event, survey_id = p_survey, deadline = p_deadline, starts_at = p_starts, points = p_points,
    reason = left(trim(p_reason), 200), revoke_noshow = p_kind = 'rsvp' and coalesce(p_noshow, false)
  where id = p_id returning * into r;
  if old.kind is distinct from r.kind or old.event_id is distinct from r.event_id or old.survey_id is distinct from r.survey_id then
    delete from point_awards where rule_id = p_id;
  else
    update point_awards set points = r.points, reason = r.reason where rule_id = p_id;
    delete from point_awards pa where pa.rule_id = p_id and pa.email not in (select public.rule_qualifiers(r));
  end if;
  insert into change_log (text) values ('Edited the point rule “' || r.reason || '”');
  return public.apply_point_rules();
end $$;
revoke execute on function public.edit_point_rule(uuid, text, uuid, uuid, timestamptz, int, text, boolean, timestamptz) from public, anon;
grant execute on function public.edit_point_rule(uuid, text, uuid, uuid, timestamptz, int, text, boolean, timestamptz) to authenticated;
