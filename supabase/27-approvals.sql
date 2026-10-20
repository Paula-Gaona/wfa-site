-- WFA update: approvals.
-- Presidents, vice presidents, faculty advisors, admins, and officers an admin allows ("can publish") change
-- member-visible content directly. Other officers submit changes to an approval inbox that
-- presidents, vice presidents, and admins review. Run once in Supabase -> SQL Editor. Safe to run again.

-- ---------- Who can publish, who can approve ----------
alter table public.officer_profiles add column if not exists can_publish boolean not null default false;

create or replace function public.can_publish() returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or (public.is_officer() and exists (
    select 1 from public.officer_profiles p
    where p.email = public.jwt_email() and (p.tier in ('president', 'vice_president', 'advisor') or p.can_publish)));
$$;
create or replace function public.is_approver() returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or (public.is_officer() and exists (
    select 1 from public.officer_profiles p
    where p.email = public.jwt_email() and p.tier in ('president', 'vice_president')));
$$;
grant execute on function public.can_publish() to authenticated;
grant execute on function public.is_approver() to authenticated;

-- Officers can still edit their own profile, but only admins can change rank, branch, title, or publishing rights.
create or replace function public.guard_officer_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- Admins, the invite-officer function (service role), and the SQL editor are trusted.
  if not (public.is_admin() or coalesce(auth.role(), '') = 'service_role' or session_user <> 'authenticator') then
    if tg_op = 'INSERT' then
      new.tier := 'officer'; new.branch := ''; new.can_publish := false;
    else
      new.tier := old.tier; new.branch := old.branch; new.title := old.title; new.can_publish := old.can_publish;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists guard_officer_profile on public.officer_profiles;
create trigger guard_officer_profile before insert or update on public.officer_profiles
  for each row execute function public.guard_officer_profile();

-- The public officer list picks up the new column.
drop view if exists public.officers_public;
create view public.officers_public as
  select p.*, a.role,
    coalesce(m.majors, '{}') as majors,
    coalesce(m.minor, '') as minor
  from public.officer_profiles p
  join public.access_list a using (email)
  left join public.members m on m.email = p.email;
grant select on public.officers_public to anon, authenticated;

-- ---------- Member-visible content: publishers only ----------
drop policy if exists "officers post announcements" on public.announcements;
drop policy if exists "officers edit announcements" on public.announcements;
drop policy if exists "officers delete announcements" on public.announcements;
create policy "publishers post announcements" on public.announcements for insert with check (can_publish());
create policy "publishers edit announcements" on public.announcements for update using (can_publish());
create policy "publishers delete announcements" on public.announcements for delete using (can_publish());

drop policy if exists "officers write recaps" on public.recaps;
drop policy if exists "officers delete recaps" on public.recaps;
create policy "publishers write recaps" on public.recaps for insert with check (can_publish());
create policy "publishers delete recaps" on public.recaps for delete using (can_publish());

drop policy if exists "officers add archive" on public.archive;
drop policy if exists "officers delete archive" on public.archive;
create policy "publishers add archive" on public.archive for insert with check (can_publish());
create policy "publishers delete archive" on public.archive for delete using (can_publish());

drop policy if exists "officers add careers" on public.careers;
drop policy if exists "officers edit careers" on public.careers;
drop policy if exists "officers delete careers" on public.careers;
create policy "publishers add careers" on public.careers for insert with check (can_publish());
create policy "publishers edit careers" on public.careers for update using (can_publish());
create policy "publishers delete careers" on public.careers for delete using (can_publish());

drop policy if exists "officers add resources" on public.resources;
drop policy if exists "officers edit resources" on public.resources;
drop policy if exists "officers delete resources" on public.resources;
create policy "publishers add resources" on public.resources for insert with check (can_publish());
create policy "publishers edit resources" on public.resources for update using (can_publish());
create policy "publishers delete resources" on public.resources for delete using (can_publish());

drop policy if exists "officers add timeline rows" on public.recruiting_timeline;
drop policy if exists "officers edit timeline rows" on public.recruiting_timeline;
drop policy if exists "officers delete timeline rows" on public.recruiting_timeline;
create policy "publishers add timeline rows" on public.recruiting_timeline for insert with check (can_publish());
create policy "publishers edit timeline rows" on public.recruiting_timeline for update using (can_publish());
create policy "publishers delete timeline rows" on public.recruiting_timeline for delete using (can_publish());

drop policy if exists "officers edit settings" on public.settings;
create policy "publishers edit settings" on public.settings for update using (can_publish());

-- Events: any officer can create and edit drafts; only publishers can publish, edit, or delete published events.
drop policy if exists "officers add events" on public.events;
drop policy if exists "officers edit events" on public.events;
drop policy if exists "officers delete events" on public.events;
create policy "officers add events" on public.events for insert with check (can_publish() or (is_officer() and draft));
create policy "officers edit events" on public.events for update using (can_publish() or (is_officer() and draft)) with check (can_publish() or draft);
create policy "officers delete events" on public.events for delete using (can_publish() or (is_officer() and draft));

-- Planning notes aren't member-visible, so any officer can save them on any event.
create or replace function public.set_plan_notes(ev uuid, notes text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_officer() then raise exception 'Only officers can edit planning notes.'; end if;
  update public.events set plan_notes = notes where id = ev;
end $$;
grant execute on function public.set_plan_notes(uuid, text) to authenticated;

-- ---------- The approval inbox ----------
create table if not exists public.pending_changes (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  author text not null default public.jwt_email(),
  kind text not null check (char_length(kind) <= 40),          -- event, announcement, recap, archive, resource, career, timeline, about
  action text not null check (action in ('add', 'edit', 'delete', 'publish', 'unpublish')),
  target_id text not null default '',
  payload jsonb not null default '{}'::jsonb,
  summary text not null default '' check (char_length(summary) <= 300),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  reviewed_by text not null default '',
  reviewed_at timestamptz,
  review_note text not null default ''
);
alter table public.pending_changes enable row level security;
drop policy if exists "officers submit changes" on public.pending_changes;
create policy "officers submit changes" on public.pending_changes for insert
  with check (is_officer() and author = jwt_email() and status = 'pending' and reviewed_by = '');
drop policy if exists "approvers or author read changes" on public.pending_changes;
create policy "approvers or author read changes" on public.pending_changes for select using (is_approver() or author = jwt_email());
drop policy if exists "approvers review changes" on public.pending_changes;
create policy "approvers review changes" on public.pending_changes for update using (is_approver());
drop policy if exists "approvers or author withdraw changes" on public.pending_changes;
create policy "approvers or author withdraw changes" on public.pending_changes for delete
  using (is_approver() or (author = jwt_email() and status = 'pending'));
grant select, insert, update, delete on public.pending_changes to authenticated;
