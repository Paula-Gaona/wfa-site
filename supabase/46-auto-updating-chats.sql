-- WFA update: chats that keep themselves updated ("rule" chats).
-- Admins can start a chat from filters instead of a list of people:
-- officers or members, branch, position, year in school, career interest. Anyone who matches is in the chat, now or
-- later, and anyone who stops matching drops out. The admin who made it is always in it. Only admins can make,
-- change, or delete these chats. (Test accounts are never included.)
-- Also: any officer can start a one-on-one chat with another officer (group chats and chats with members stay
-- limited to presidents, vice presidents, faculty advisors, and admins).
-- Run once in Supabase -> SQL Editor, after 45. Safe to run again.

alter table public.chats add column if not exists rule jsonb;   -- {who, branch, tier, year, interest}; empty = any
alter table public.chats drop constraint if exists chats_kind_check;
alter table public.chats add constraint chats_kind_check
  check (kind in ('officers', 'executives', 'branch', 'branch_leads', 'team', 'all_teams', 'forming', 'custom', 'direct', 'rule'));

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
    -- Rule chats: everyone who matches the filters, plus whoever made the chat.
    union select m.email from members m
      left join access_list a on a.email = m.email
      left join officer_profiles p on p.email = m.email
      where c.kind = 'rule'
        and not exists (select 1 from test_accounts t where t.email = m.email)
        and (coalesce(c.rule ->> 'who', '') = '' or (c.rule ->> 'who' = 'officer') = (a.email is not null))
        and (coalesce(c.rule ->> 'branch', '') = '' or p.branch = c.rule ->> 'branch')
        and (coalesce(c.rule ->> 'tier', '') = ''
             or (c.rule ->> 'tier' = 'officer' and p.tier in ('officer', 'honorary'))
             or p.tier = c.rule ->> 'tier')
        and (coalesce(c.rule ->> 'year', '') = '' or m.year = c.rule ->> 'year')
        and (coalesce(c.rule ->> 'interest', '') = '' or (c.rule ->> 'interest') = any(m.interests))
    union select c.created_by where c.kind = 'rule'
  ) x where c.id = cid;
$$;

-- Make or change a rule chat (admins only).
create or replace function public.save_rule_chat(p_chat uuid, p_title text, p_rule jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); cid uuid; r jsonb;
begin
  if not public.is_admin() then return 'err:notadmin'; end if;
  if trim(coalesce(p_title, '')) = '' then return 'err:title'; end if;
  r := jsonb_build_object('who', coalesce(p_rule ->> 'who', ''), 'branch', coalesce(p_rule ->> 'branch', ''), 'tier', coalesce(p_rule ->> 'tier', ''),
                          'year', coalesce(p_rule ->> 'year', ''), 'interest', coalesce(p_rule ->> 'interest', ''));
  if p_chat is null then
    insert into chats (kind, title, rule, created_by) values ('rule', left(trim(p_title), 80), r, me) returning id into cid;
    return cid::text;
  end if;
  update chats set title = left(trim(p_title), 80), rule = r
    where id = p_chat and kind = 'rule';
  if not found then return 'err:missing'; end if;
  return p_chat::text;
end $$;
grant execute on function public.save_rule_chat(uuid, text, jsonb) to authenticated;

drop policy if exists "creators delete their chats" on public.chats;
create policy "creators delete their chats" on public.chats for delete
  using ((created_by = jwt_email() and kind in ('custom', 'forming')) or (is_admin() and kind = 'rule'));

-- The site's chat list now includes each rule chat's filters.
create or replace function public.my_chats() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(x order by coalesce(x.last_message_at, x.created_at) desc), '[]'::json) from (
    select c.id, c.kind, c.title, c.branch, c.event_id, c.team_id, c.created_at, c.last_message_at, c.rule,
      c.created_by = public.jwt_email() as mine,
      exists (select 1 from chat_member_emails(c.id) e where e.email = public.jwt_email()) as member,
      (select coalesce(json_agg(json_build_object(
          'email', case when public.is_officer() or e.email = public.jwt_email() then e.email end,
          'me', e.email = public.jwt_email(), 'first', m.first, 'last', m.last,
          'officer', exists (select 1 from access_list a where a.email = e.email)) order by m.first), '[]'::json)
        from chat_member_emails(c.id) e left join members m on m.email = e.email) as people,
      case when exists (select 1 from chat_member_emails(c.id) e where e.email = public.jwt_email()) then
        (select count(*) from messages g where g.chat_id = c.id and g.email <> public.jwt_email()
           and g.created_at > coalesce((select r.last_read_at from chat_reads r where r.chat_id = c.id and r.email = public.jwt_email()), '-infinity'))::int
        else 0 end as unread,
      (select json_build_object('body', left(g.body, 140), 'at', g.created_at, 'me', g.email = public.jwt_email(),
          'first', (select m.first from members m where m.email = g.email))
        from messages g where g.chat_id = c.id order by g.created_at desc limit 1) as last
    from chats c where public.can_access_chat(c.id)
  ) x;
$$;
grant execute on function public.my_chats() to authenticated;

-- Starting chats: any officer can message another officer one-on-one.
create or replace function public.create_chat(p_kind text, p_title text, p_emails text[], p_event uuid default null) returns text
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email(); cid uuid; ems text[]; missing text;
begin
  if auth.uid() is null then return 'err:signin'; end if;
  select coalesce(array_agg(distinct x), '{}') into ems
    from (select lower(trim(u)) as x from unnest(coalesce(p_emails, '{}'::text[])) u) s where x <> '' and x <> me;
  select string_agg(x, ', ') into missing from unnest(ems) x where not exists (select 1 from members m where m.email = x);
  if missing is not null then return 'err:noaccount:' || missing; end if;

  if p_kind = 'custom' then
    if cardinality(ems) = 0 then return 'err:nobody'; end if;
    -- Presidents, VPs, advisors, and admins start any chat. Other officers: one-on-one with another officer only.
    if not public.is_leader() then
      if not public.is_officer() then return 'err:notleader'; end if;
      if cardinality(ems) <> 1 or coalesce(trim(p_title), '') <> ''
         or not exists (select 1 from access_list a where a.email = ems[1]) then return 'err:officeronly'; end if;
    end if;
    -- An untitled one-on-one with the same person opens the existing chat.
    if cardinality(ems) = 1 and coalesce(trim(p_title), '') = '' then
      select c.id into cid from chats c where c.kind = 'custom' and c.title = ''
        and (select count(*) from chat_members m where m.chat_id = c.id) = 2
        and exists (select 1 from chat_members m where m.chat_id = c.id and m.email = me)
        and exists (select 1 from chat_members m where m.chat_id = c.id and m.email = ems[1]) limit 1;
      if cid is not null then return cid::text; end if;
    end if;
    insert into chats (kind, title, created_by) values ('custom', left(trim(coalesce(p_title, '')), 80), me) returning id into cid;
    insert into chat_members (chat_id, email) select cid, x from unnest(ems || me) x;
    return cid::text;

  elsif p_kind = 'direct' then
    if cardinality(ems) <> 1 then return 'err:one'; end if;
    if not exists (select 1 from case_team_members a join case_team_members b on a.team_id = b.team_id
                   where a.email = me and b.email = ems[1] and a.confirmed and b.confirmed) then return 'err:notteammate'; end if;
    select c.id into cid from chats c where c.kind = 'direct'
      and exists (select 1 from chat_members m where m.chat_id = c.id and m.email = me)
      and exists (select 1 from chat_members m where m.chat_id = c.id and m.email = ems[1]) limit 1;
    if cid is not null then return cid::text; end if;
    insert into chats (kind, created_by) values ('direct', me) returning id into cid;
    insert into chat_members (chat_id, email) values (cid, me), (cid, ems[1]);
    return cid::text;

  elsif p_kind = 'forming' then
    if p_event is null or not exists (select 1 from events e where e.id = p_event and e.cat = 'case_competition' and not e.draft
         and e.test = public.is_test() and now() < (e.date + e.start_time) at time zone 'America/Denver') then return 'err:event'; end if;
    select c.id into cid from chats c where c.kind = 'forming' and c.event_id = p_event and c.created_by = me limit 1;
    if cid is not null then
      insert into chat_members (chat_id, email) select cid, x from unnest(ems) x on conflict do nothing;
      return cid::text;
    end if;
    insert into chats (kind, title, event_id, created_by)
      values ('forming', coalesce(nullif(left(trim(coalesce(p_title, '')), 80), ''), 'Forming a team'), p_event, me) returning id into cid;
    insert into chat_members (chat_id, email) select cid, x from unnest(ems || me) x;
    return cid::text;
  end if;
  return 'err:kind';
end $$;
grant execute on function public.create_chat(text, text, text[], uuid) to authenticated;
