-- WFA update: chats (live messaging on the site).
-- Automatic chats, whose membership updates itself:
--   * officers  - "Leadership Team": every officer and the faculty advisor (everyone on the access list)
--   * branch    - one per branch: officers in that branch, plus presidents
--   * team      - one per accepted case competition team: its confirmed teammates
--   * all_teams - one per case competition: confirmed teammates on every accepted team
--   (Officers can open team and all-teams chats to help; they count as members once they post.)
-- Chats people start, with a member list:
--   * custom  - presidents, vice presidents, faculty advisors, and admins start chats with officers and/or members
--   * direct  - a member messages someone on their own case competition team
--   * forming - a member starts a chat to put a team together for a case competition and adds people to it
-- Only people in a chat can read it. Unread messages get one summary email after an hour (members can turn it off).
-- Run once in Supabase -> SQL Editor, after 41. Safe to run again.

-- ---------- Tables ----------
create table if not exists public.chats (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('officers', 'branch', 'team', 'all_teams', 'forming', 'custom', 'direct')),
  title text not null default '' check (char_length(title) <= 80),
  branch text,
  event_id uuid references public.events (id) on delete cascade,
  team_id uuid references public.case_teams (id) on delete cascade,
  created_by text not null default public.jwt_email(),
  created_at timestamptz not null default now(),
  last_message_at timestamptz
);
create unique index if not exists chats_one_officers on public.chats (kind) where kind = 'officers';
create unique index if not exists chats_one_per_branch on public.chats (branch) where kind = 'branch';
create unique index if not exists chats_one_per_team on public.chats (team_id) where kind = 'team';
create unique index if not exists chats_one_all_teams on public.chats (event_id) where kind = 'all_teams';

create table if not exists public.chat_members (
  chat_id uuid not null references public.chats (id) on delete cascade,
  email text not null check (email = lower(email)),
  added_at timestamptz not null default now(),
  primary key (chat_id, email)
);
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  chat_id uuid not null references public.chats (id) on delete cascade,
  email text not null default public.jwt_email(),
  body text not null check (char_length(trim(body)) between 1 and 4000),
  created_at timestamptz not null default now()
);
create index if not exists messages_by_chat on public.messages (chat_id, created_at desc);
create table if not exists public.chat_reads (
  chat_id uuid not null references public.chats (id) on delete cascade,
  email text not null default public.jwt_email(),
  last_read_at timestamptz not null default now(),
  primary key (chat_id, email)
);
create table if not exists public.chat_alerts (email text primary key, last_alert_at timestamptz not null);
alter table public.members add column if not exists chat_emails boolean not null default true;

-- ---------- Who's in a chat ----------
create or replace function public.is_leader() returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or (public.is_officer() and exists (
    select 1 from officer_profiles p where p.email = public.jwt_email() and p.tier in ('president', 'vice_president', 'advisor')));
$$;
grant execute on function public.is_leader() to authenticated;

create or replace function public.chat_member_emails(cid uuid) returns table (email text)
language sql stable security definer set search_path = public as $$
  select x.email from chats c cross join lateral (
    select a.email from access_list a where c.kind = 'officers'
    union select a.email from access_list a join officer_profiles p on p.email = a.email
      where c.kind = 'branch' and (p.branch = c.branch or p.tier = 'president')
    union select cm.email from case_team_members cm join case_teams t on t.id = cm.team_id
      where c.kind = 'team' and cm.team_id = c.team_id and cm.confirmed and t.status = 'in'
    union select cm.email from case_team_members cm join case_teams t on t.id = cm.team_id
      where c.kind = 'all_teams' and cm.event_id = c.event_id and cm.confirmed and t.status = 'in'
    union select distinct m.email from messages m join access_list a on a.email = m.email
      where c.kind in ('team', 'all_teams') and m.chat_id = c.id
    union select ch.email from chat_members ch where c.kind in ('forming', 'custom', 'direct') and ch.chat_id = c.id
  ) x where c.id = cid;
$$;
revoke execute on function public.chat_member_emails(uuid) from public, anon;
grant execute on function public.chat_member_emails(uuid) to authenticated;

create or replace function public.can_access_chat(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    exists (select 1 from chat_member_emails(cid) e where e.email = public.jwt_email())
    or exists (select 1 from chats c where c.id = cid and c.kind in ('team', 'all_teams') and public.can_manage_case(c.event_id)));
$$;
grant execute on function public.can_access_chat(uuid) to authenticated;

-- ---------- Access rules ----------
alter table public.chats enable row level security;
alter table public.chat_members enable row level security;
alter table public.messages enable row level security;
alter table public.chat_reads enable row level security;
alter table public.chat_alerts enable row level security;

drop policy if exists "chat members read chats" on public.chats;
create policy "chat members read chats" on public.chats for select using (can_access_chat(id));
drop policy if exists "creators delete their chats" on public.chats;
create policy "creators delete their chats" on public.chats for delete using (created_by = jwt_email() and kind in ('custom', 'forming'));
drop policy if exists "chat members read member list" on public.chat_members;
create policy "chat members read member list" on public.chat_members for select using (can_access_chat(chat_id));
drop policy if exists "chat members read messages" on public.messages;
create policy "chat members read messages" on public.messages for select using (can_access_chat(chat_id));
drop policy if exists "chat members send messages" on public.messages;
create policy "chat members send messages" on public.messages for insert with check (email = jwt_email() and can_access_chat(chat_id));
drop policy if exists "authors and leaders delete messages" on public.messages;
create policy "authors and leaders delete messages" on public.messages for delete using (email = jwt_email() or (is_leader() and can_access_chat(chat_id)));
drop policy if exists "own read markers" on public.chat_reads;
create policy "own read markers" on public.chat_reads for all using (email = jwt_email()) with check (email = jwt_email());
-- chat_alerts: no policies, so only the auto-emails function (service role) uses it.

-- Explicit grants (required for new tables from Oct 30, 2026). The policies above still decide access.
grant select, delete on public.chats to authenticated;
grant select on public.chat_members to authenticated;
grant select, insert, delete on public.messages to authenticated;
grant select, insert, update, delete on public.chat_reads to authenticated;
grant select, insert, update, delete on public.chats, public.chat_members, public.messages, public.chat_reads, public.chat_alerts to service_role;

-- Keep each chat's latest-message time up to date (for sorting).
create or replace function public.touch_chat() returns trigger
language plpgsql security definer set search_path = public as $$
begin update chats set last_message_at = new.created_at where id = new.chat_id; return new; end $$;
drop trigger if exists messages_touch_chat on public.messages;
create trigger messages_touch_chat after insert on public.messages for each row execute function public.touch_chat();

-- Live updates: new messages are pushed to the site as they're sent (access rules still apply).
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages') then
    alter publication supabase_realtime add table public.messages;
  end if;
end $$;

-- ---------- Automatic chats ----------
insert into public.chats (kind, title, created_by) select 'officers', 'Leadership Team', 'system'
  where not exists (select 1 from public.chats where kind = 'officers');
insert into public.chats (kind, branch, title, created_by)
  select 'branch', b, initcap(replace(b, '_', ' ')), 'system' from unnest(array['communications', 'operations', 'financial_applications']) b
  where not exists (select 1 from public.chats c where c.kind = 'branch' and c.branch = b);

-- When a case competition team is accepted, make its team chat and the competition's all-teams chat.
create or replace function public.ensure_case_chats() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'in' then
    insert into chats (kind, title, event_id, team_id, created_by) values ('team', left(new.name, 80), new.event_id, new.id, 'system')
      on conflict (team_id) where kind = 'team' do update set title = excluded.title;
    insert into chats (kind, title, event_id, created_by)
      select 'all_teams', left(e.title || ': all teams', 80), e.id, 'system' from events e where e.id = new.event_id
      on conflict (event_id) where kind = 'all_teams' do nothing;
  end if;
  return new;
end $$;
drop trigger if exists case_teams_chats on public.case_teams;
create trigger case_teams_chats after insert or update of status, name on public.case_teams for each row execute function public.ensure_case_chats();
-- Teams already accepted before this update:
update public.case_teams set status = status where status = 'in';

-- ---------- What members can do ----------
-- Start a chat. p_kind: 'custom' (leaders), 'direct' (a case competition teammate), 'forming' (putting a team together).
-- Returns the chat id, or 'err:<reason>'.
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
    if not public.is_leader() then return 'err:notleader'; end if;
    if cardinality(ems) = 0 then return 'err:nobody'; end if;
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

-- The person who started a chat adds or removes people. Anyone can leave a chat they were added to.
create or replace function public.chat_add(p_chat uuid, p_email text) returns text
language plpgsql security definer set search_path = public as $$
declare c chats; em text := lower(trim(coalesce(p_email, '')));
begin
  select * into c from chats where id = p_chat;
  if c.id is null then return 'err:missing'; end if;
  if c.kind not in ('custom', 'forming') or c.created_by <> public.jwt_email() then return 'err:notowner'; end if;
  if not exists (select 1 from members m where m.email = em) then return 'err:noaccount:' || em; end if;
  insert into chat_members (chat_id, email) values (p_chat, em) on conflict do nothing;
  return 'ok';
end $$;
create or replace function public.chat_remove(p_chat uuid, p_email text) returns text
language plpgsql security definer set search_path = public as $$
declare c chats; em text := lower(trim(coalesce(p_email, ''))); me text := public.jwt_email();
begin
  select * into c from chats where id = p_chat;
  if c.id is null then return 'err:missing'; end if;
  if c.kind not in ('custom', 'forming', 'direct') then return 'err:automatic'; end if;
  if em <> me and (c.kind = 'direct' or c.created_by <> me) then return 'err:notowner'; end if;
  delete from chat_members where chat_id = p_chat and email = em;
  return 'ok';
end $$;
grant execute on function public.chat_add(uuid, text) to authenticated;
grant execute on function public.chat_remove(uuid, text) to authenticated;

-- Mark a chat as read (server time, so unread counts are right on every device).
create or replace function public.mark_chat_read(p_chat uuid) returns void
language sql security definer set search_path = public as $$
  insert into chat_reads (chat_id, email, last_read_at) select p_chat, public.jwt_email(), now() where public.can_access_chat(p_chat)
  on conflict (chat_id, email) do update set last_read_at = now();
$$;
grant execute on function public.mark_chat_read(uuid) to authenticated;

-- ---------- What the site shows ----------
-- Every chat the signed-in person can open: its people (emails only shown to officers, or for yourself),
-- the latest message, and how many unread messages there are.
create or replace function public.my_chats() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(x order by coalesce(x.last_message_at, x.created_at) desc), '[]'::json) from (
    select c.id, c.kind, c.title, c.branch, c.event_id, c.team_id, c.created_at, c.last_message_at,
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

-- Message authors' names for a chat (members can't read other members' profiles directly).
create or replace function public.chat_names(p_chat uuid) returns table (email text, first text, last text)
language sql stable security definer set search_path = public as $$
  select distinct g.email, m.first, m.last from messages g left join members m on m.email = g.email
  where g.chat_id = p_chat and public.can_access_chat(p_chat);
$$;
grant execute on function public.chat_names(uuid) to authenticated;

-- For the auto-emails function only: who has messages unread for over an hour since their last chat email.
create or replace function public.chat_digest() returns table (email text, first text, unread int, chats text)
language sql stable security definer set search_path = public as $$
  with mem as (select c.id as chat_id, coalesce(nullif(c.title, ''), 'a direct message') as title, e.email
               from chats c cross join lateral chat_member_emails(c.id) e),
  un as (
    select mem.email, mem.title, count(*) as n from mem
    join messages g on g.chat_id = mem.chat_id and g.email <> mem.email
    left join chat_reads r on r.chat_id = mem.chat_id and r.email = mem.email
    left join chat_alerts al on al.email = mem.email
    where g.created_at > coalesce(r.last_read_at, '-infinity') and g.created_at <= now() - interval '1 hour'
      and g.created_at > coalesce(al.last_alert_at, '-infinity')
    group by mem.email, mem.title)
  select un.email, m.first, sum(un.n)::int, string_agg(un.title, ', ' order by un.title)
  from un join members m on m.email = un.email and m.chat_emails
  where not exists (select 1 from test_accounts t where t.email = un.email)
  group by un.email, m.first;
$$;
revoke execute on function public.chat_digest() from public, anon, authenticated;
