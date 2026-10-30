-- WFA update: survey builder. Officers make surveys (short answer, paragraph, multiple choice, checkboxes, dropdown,
-- rating, yes/no) and give each question its own points. A member earns a question's points by answering it, and
-- the total goes on the leaderboard (as one award per survey, updated if they change their answers). Surveys can be
-- shown on the home page and the Leaderboard page. Members must be signed in to take one.
-- Run once in Supabase -> SQL Editor. Safe to run again.

create table if not exists public.surveys (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  created_by text not null default public.jwt_email(),
  title text not null check (char_length(title) between 1 and 120),
  descr text not null default '' check (char_length(descr) <= 2000),
  -- [{id, type: short|long|single|multi|dropdown|rating|yesno, label, hint, required, options: [..], points}]
  questions jsonb not null default '[]' check (jsonb_typeof(questions) = 'array' and jsonb_array_length(questions) <= 60),
  status text not null default 'draft' check (status in ('draft', 'open', 'closed')),
  closes_at timestamptz,
  show_home boolean not null default true,
  show_leaderboard boolean not null default true
);
alter table public.surveys enable row level security;
drop policy if exists "members read open surveys" on public.surveys;
create policy "members read open surveys" on public.surveys for select using (status <> 'draft' or public.is_officer());
drop policy if exists "officers write surveys" on public.surveys;
create policy "officers write surveys" on public.surveys for all using (public.is_officer()) with check (public.is_officer());
grant select on public.surveys to anon, authenticated;
grant insert, update, delete on public.surveys to authenticated;
grant select, insert, update, delete on public.surveys to service_role;

create table if not exists public.survey_responses (
  survey_id uuid not null references public.surveys (id) on delete cascade,
  email text not null default public.jwt_email(),
  answers jsonb not null default '{}',
  points int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (survey_id, email)
);
alter table public.survey_responses enable row level security;
drop policy if exists "own or officers read survey responses" on public.survey_responses;
create policy "own or officers read survey responses" on public.survey_responses for select using (email = public.jwt_email() or public.is_officer());
drop policy if exists "officers delete survey responses" on public.survey_responses;
create policy "officers delete survey responses" on public.survey_responses for delete using (public.is_officer());
grant select, delete on public.survey_responses to authenticated;
grant select, insert, update, delete on public.survey_responses to service_role;

-- Survey points go on the leaderboard as point awards (one per person per survey).
alter table public.point_awards add column if not exists survey_id uuid references public.surveys (id) on delete cascade;
create unique index if not exists point_awards_survey_once on public.point_awards (survey_id, email) where survey_id is not null;

-- Is this answer filled in?
create or replace function public.survey_answered(v jsonb) returns boolean
language sql immutable as $$
  select v is not null and case jsonb_typeof(v) when 'string' then btrim(v #>> '{}') <> ''
    when 'array' then jsonb_array_length(v) > 0 when 'null' then false else true end;
$$;

-- Submit (or update) my answers. Checks required questions, adds up the points for every question answered, and
-- keeps my leaderboard award for this survey in step. Returns 'ok:<points>' or an error code.
create or replace function public.submit_survey(p_survey uuid, p_answers jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); s surveys; q jsonb; v jsonb; pts int := 0; clean jsonb := '{}';
begin
  if auth.uid() is null or me is null or not exists (select 1 from members where email = me) then return 'err:signin'; end if;
  select * into s from surveys where id = p_survey;
  if s.id is null or s.status = 'draft' then return 'err:missing'; end if;
  if s.status = 'closed' or (s.closes_at is not null and now() >= s.closes_at) then return 'err:closed'; end if;
  if jsonb_typeof(coalesce(p_answers, '{}')) <> 'object' or octet_length(p_answers::text) > 60000 then return 'err:size'; end if;
  for q in select x from jsonb_array_elements(s.questions) x loop
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

-- How many people have answered each survey (for the cards on the home and Leaderboard pages).
create or replace function public.survey_counts() returns table (survey_id uuid, responses int)
language sql stable security definer set search_path = public as $$
  select r.survey_id, count(*)::int from survey_responses r join surveys s on s.id = r.survey_id where s.status <> 'draft' group by r.survey_id;
$$;
grant execute on function public.survey_counts() to anon, authenticated;
