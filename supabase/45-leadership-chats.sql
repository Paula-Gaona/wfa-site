-- WFA update: two more automatic chats.
--   * executives   - "Executive Board": every president and vice president
--   * branch_leads - one per branch ("Operations leadership"): that branch's president(s) and vice president(s),
--                    paired by the branch on their officer profile
-- Membership updates itself as officers' positions and branches change. Run once in Supabase -> SQL Editor, after 44.
-- Safe to run again.

alter table public.chats drop constraint if exists chats_kind_check;
alter table public.chats add constraint chats_kind_check
  check (kind in ('officers', 'executives', 'branch', 'branch_leads', 'team', 'all_teams', 'forming', 'custom', 'direct'));
create unique index if not exists chats_one_executives on public.chats (kind) where kind = 'executives';
create unique index if not exists chats_one_branch_leads on public.chats (branch) where kind = 'branch_leads';

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
  ) x where c.id = cid;
$$;

insert into public.chats (kind, title, created_by) select 'executives', 'Executive Board', 'system'
  where not exists (select 1 from public.chats where kind = 'executives');
insert into public.chats (kind, branch, title, created_by)
  select 'branch_leads', b, initcap(replace(b, '_', ' ')) || ' leadership', 'system'
  from unnest(array['communications', 'operations', 'financial_applications']) b
  where not exists (select 1 from public.chats c where c.kind = 'branch_leads' and c.branch = b);
