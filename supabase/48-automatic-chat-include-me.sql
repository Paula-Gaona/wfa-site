-- WFA update: automatic chats can leave out the admin who made them. If they do, the admin writes a first message
-- (posted under their name) so people know why they're in the chat. Admins can't read automatic chats they aren't in,
-- but can manage them (name, filters, delete) from a list.
-- Run once in Supabase -> SQL Editor, after 47. Safe to run again.

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
    -- The admin who made it, unless they chose to leave themselves out.
    union select c.created_by where c.kind = 'rule' and coalesce((c.rule ->> 'include_creator')::boolean, true)
  ) x where c.id = cid;
$$;

-- Admins manage automatic chats from a list (name, filters, how many people), without seeing their messages
-- unless they're in them.
create or replace function public.rule_chats() returns table (id uuid, title text, rule jsonb, created_by text, people int, member boolean)
language sql stable security definer set search_path = public as $$
  select c.id, c.title, c.rule, c.created_by, (select count(*) from chat_member_emails(c.id))::int,
    exists (select 1 from chat_member_emails(c.id) e where e.email = public.jwt_email())
  from chats c where c.kind = 'rule' and public.is_admin() order by c.title;
$$;
grant execute on function public.rule_chats() to authenticated;
create or replace function public.delete_rule_chat(p_chat uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then return 'err:notadmin'; end if;
  delete from chats where id = p_chat and kind = 'rule';
  return 'ok';
end $$;
grant execute on function public.delete_rule_chat(uuid) to authenticated;

-- Make or change an automatic chat. p_message is the first message (required when the admin leaves themselves out
-- and doesn't match the filters; an admin who matches is in the chat either way).
drop function if exists public.save_rule_chat(uuid, text, jsonb);
create or replace function public.save_rule_chat(p_chat uuid, p_title text, p_rule jsonb, p_message text default '') returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); cid uuid; r jsonb; incl boolean := coalesce((p_rule ->> 'include_creator')::boolean, true);
begin
  if not public.is_admin() then return 'err:notadmin'; end if;
  if trim(coalesce(p_title, '')) = '' then return 'err:title'; end if;
  if char_length(coalesce(p_message, '')) > 4000 then return 'err:long'; end if;
  r := jsonb_build_object('who', to_jsonb(rule_vals(p_rule, 'who')), 'branch', to_jsonb(rule_vals(p_rule, 'branch')),
                          'tier', to_jsonb(rule_vals(p_rule, 'tier')), 'year', to_jsonb(rule_vals(p_rule, 'year')),
                          'interest', to_jsonb(rule_vals(p_rule, 'interest')), 'include_creator', incl);
  if p_chat is null then
    insert into chats (kind, title, rule, created_by) values ('rule', left(trim(p_title), 80), r, me) returning id into cid;
    if trim(coalesce(p_message, '')) = '' and not exists (select 1 from chat_member_emails(cid) e where e.email = me) then
      delete from chats where id = cid;
      return 'err:message';
    end if;
  else
    update chats set title = left(trim(p_title), 80), rule = r where id = p_chat and kind = 'rule' returning id into cid;
    if cid is null then return 'err:missing'; end if;
  end if;
  if trim(coalesce(p_message, '')) <> '' then insert into messages (chat_id, email, body) values (cid, me, trim(p_message)); end if;
  return cid::text;
end $$;
grant execute on function public.save_rule_chat(uuid, text, jsonb, text) to authenticated;
