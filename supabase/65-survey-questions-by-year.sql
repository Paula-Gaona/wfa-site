-- WFA update: survey questions can be shown only to certain years in school (a question's "years" list; empty means
-- everyone). Members only answer, earn points for, and are required to answer the questions shown to their year
-- (the year on their profile, which the survey asks for if it's missing). Run once in Supabase -> SQL Editor, after
-- 63-survey-builder.sql. Safe to run again.

create or replace function public.submit_survey(p_survey uuid, p_answers jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); s surveys; q jsonb; v jsonb; pts int := 0; clean jsonb := '{}'; yr text;
begin
  if auth.uid() is null or me is null or not exists (select 1 from members where email = me) then return 'err:signin'; end if;
  select * into s from surveys where id = p_survey;
  if s.id is null or s.status = 'draft' then return 'err:missing'; end if;
  if s.status = 'closed' or (s.closes_at is not null and now() >= s.closes_at) then return 'err:closed'; end if;
  if jsonb_typeof(coalesce(p_answers, '{}')) <> 'object' or octet_length(p_answers::text) > 60000 then return 'err:size'; end if;
  select coalesce(m.year, '') into yr from members m where m.email = me;
  for q in select x from jsonb_array_elements(s.questions) x loop
    -- Questions for other years are skipped (not shown, not required, no points).
    if jsonb_array_length(coalesce(q->'years', '[]')) > 0 and not (coalesce(q->'years', '[]') ? yr) then continue; end if;
    v := p_answers -> (q->>'id');
    if public.survey_answered(v) then
      clean := clean || jsonb_build_object(q->>'id', v);
      pts := pts + greatest(0, least(1000, coalesce((q->>'points')::int, 0)));
    elsif coalesce((q->>'required')::boolean, false) then
      return 'err:required:' || (q->>'id');
    end if;
  end loop;
  insert into survey_responses (survey_id, email, answers, points) values (p_survey, me, clean, pts)
    on conflict (survey_id, email) do update set answers = excluded.answers, points = excluded.points, updated_at = now();
  -- Officers and test accounts aren't ranked, so they don't get points.
  if pts > 0 and not exists (select 1 from access_list a where a.email = me) and not exists (select 1 from test_accounts t where t.email = me) then
    insert into point_awards (email, points, reason, awarded_by, survey_id)
      values (me, least(pts, 1000), left('Survey: ' || s.title, 200), 'survey', p_survey)
      on conflict (survey_id, email) where survey_id is not null do update set points = excluded.points, reason = excluded.reason;
  else
    delete from point_awards where survey_id = p_survey and email = me;
  end if;
  return 'ok:' || pts;
end $$;
grant execute on function public.submit_survey(uuid, jsonb) to authenticated;
