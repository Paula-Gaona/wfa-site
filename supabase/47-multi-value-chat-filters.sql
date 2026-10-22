-- WFA update: automatic chats can use several values per filter (for example branches Operations + Communications,
-- years Junior + Senior). Within a filter, matching any value counts; across filters, all must match.
-- Older automatic chats saved single values; those still work. Run once in Supabase -> SQL Editor, after 46.
-- Safe to run again.

-- A rule's values for one filter, as a list (accepts a list or a single value; empty = any).
create or replace function public.rule_vals(r jsonb, k text) returns text[]
language sql immutable as $$
  select case
    when r is null or r -> k is null then '{}'::text[]
    when jsonb_typeof(r -> k) = 'array' then coalesce((select array_agg(x) from jsonb_array_elements_text(r -> k) x where x <> ''), '{}')
    when coalesce(r ->> k, '') = '' then '{}'::text[]
    else array[r ->> k] end;
$$;

create or replace function public.chat_member_emails(cid uuid) returns table (email text)
language sql stable security definer set search_path = public as $$
  select x.email from chats c cross join lateral (
    select a.email from access_list a where c.kind = 'officers'
    union select a.email from access_list a join officer_profiles p on p.email = a.email
      where c.kind = 'executives' and p.tier in ('president', 'vice_president')
    union select a.email from access_list a join officer_profiles p on p.email = a.email
      where c.kind = 'branch' and p.branch = c.branch
    union select a.email from access_list a join officer_profiles p on p.email = a.email
      where c.kind = 'branch_leads' and p.branch = c.branch and p.tier in ('president', 'vice_president')
    union select cm.email from case_team_members cm join case_teams t on t.id = cm.team_id
      where c.kind = 'team' and cm.team_id = c.team_id and cm.confirmed and t.status = 'in'
    union select cm.email from case_team_members cm join case_teams t on t.id = cm.team_id
      where c.kind = 'all_teams' and cm.event_id = c.event_id and cm.confirmed and t.status = 'in'
    union select distinct m.email from messages m join access_list a on a.email = m.email
      where c.kind in ('team', 'all_teams') and m.chat_id = c.id
    union select ch.email from chat_members ch where c.kind in ('forming', 'custom', 'direct') and ch.chat_id = c.id
    -- Automatic chats: everyone who matches every filter (any of the values chosen in each), plus whoever made it.
    union select m.email from members m
      left join access_list a on a.email = m.email
      left join officer_profiles p on p.email = m.email
      where c.kind = 'rule'
        and not exists (select 1 from test_accounts t where t.email = m.email)
        and (cardinality(rule_vals(c.rule, 'who')) = 0 or (case when a.email is null then 'member' else 'officer' end) = any(rule_vals(c.rule, 'who')))
        and (cardinality(rule_vals(c.rule, 'branch')) = 0 or p.branch = any(rule_vals(c.rule, 'branch')))
        and (cardinality(rule_vals(c.rule, 'tier')) = 0 or p.tier = any(rule_vals(c.rule, 'tier'))
             or (p.tier = 'honorary' and 'officer' = any(rule_vals(c.rule, 'tier'))))
        and (cardinality(rule_vals(c.rule, 'year')) = 0 or m.year = any(rule_vals(c.rule, 'year')))
        and (cardinality(rule_vals(c.rule, 'interest')) = 0 or m.interests && rule_vals(c.rule, 'interest'))
    union select c.created_by where c.kind = 'rule'
  ) x where c.id = cid;
$$;

create or replace function public.save_rule_chat(p_chat uuid, p_title text, p_rule jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); cid uuid; r jsonb;
begin
  if not public.is_admin() then return 'err:notadmin'; end if;
  if trim(coalesce(p_title, '')) = '' then return 'err:title'; end if;
  r := jsonb_build_object('who', to_jsonb(rule_vals(p_rule, 'who')), 'branch', to_jsonb(rule_vals(p_rule, 'branch')),
                          'tier', to_jsonb(rule_vals(p_rule, 'tier')), 'year', to_jsonb(rule_vals(p_rule, 'year')),
                          'interest', to_jsonb(rule_vals(p_rule, 'interest')));
  if p_chat is null then
    insert into chats (kind, title, rule, created_by) values ('rule', left(trim(p_title), 80), r, me) returning id into cid;
    return cid::text;
  end if;
  update chats set title = left(trim(p_title), 80), rule = r where id = p_chat and kind = 'rule';
  if not found then return 'err:missing'; end if;
  return p_chat::text;
end $$;
grant execute on function public.save_rule_chat(uuid, text, jsonb) to authenticated;
