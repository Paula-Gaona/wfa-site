-- WFA update: admins can edit an automatic point rule (Admin -> Award points -> Rules -> Edit). Changing the points or
-- reason updates everyone who already has them. Changing the deadline gives the points to anyone who now qualifies and
-- takes them from anyone who no longer does. Changing what earns the points, or the event or survey, starts it over.
-- Run once in Supabase -> SQL Editor, after 64-survey-point-rules.sql. Safe to run again.

-- Who qualifies for a rule right now (same as apply_point_rules, before any RSVP no-show removals).
create or replace function public.rule_qualifiers(r point_rules) returns setof text
language sql stable security definer set search_path = public as $$
  select q.email from (
    select m.email from members m join auth.users u on u.id = m.id where r.kind = 'join' and u.created_at < date_trunc('minute', r.deadline) + interval '1 minute'
    union select x.email from rsvps x where r.kind = 'rsvp' and x.event_id = r.event_id and x.created_at < date_trunc('minute', r.deadline) + interval '1 minute'
    union select x.email from attendance x where r.kind = 'checkin' and x.event_id = r.event_id and x.created_at < date_trunc('minute', r.deadline) + interval '1 minute'
    union select x.email from event_surveys x where r.kind = 'survey' and x.event_id = r.event_id and x.created_at < date_trunc('minute', r.deadline) + interval '1 minute'
    union select x.email from survey_responses x where r.kind = 'form' and x.survey_id = r.survey_id and x.created_at < date_trunc('minute', r.deadline) + interval '1 minute'
  ) q
$$;
revoke execute on function public.rule_qualifiers(point_rules) from public, anon;

create or replace function public.edit_point_rule(p_id uuid, p_kind text, p_event uuid, p_survey uuid, p_deadline timestamptz,
  p_points int, p_reason text, p_noshow boolean) returns int
language plpgsql security definer set search_path = public as $$
declare old point_rules; r point_rules;
begin
  if not public.is_admin() then raise exception 'Only admins can do that.'; end if;
  select * into old from point_rules where id = p_id;
  if old.id is null then raise exception 'That rule doesn''t exist anymore.'; end if;
  update point_rules set kind = p_kind, event_id = p_event, survey_id = p_survey, deadline = p_deadline, points = p_points,
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
revoke execute on function public.edit_point_rule(uuid, text, uuid, uuid, timestamptz, int, text, boolean) from public, anon;
grant execute on function public.edit_point_rule(uuid, text, uuid, uuid, timestamptz, int, text, boolean) to authenticated;
