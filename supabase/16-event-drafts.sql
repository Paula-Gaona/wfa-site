-- WFA update: event drafts. Drafts are only visible to officers and admins
-- until they're published. Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.events add column if not exists draft boolean not null default false;

drop policy if exists "anyone reads events" on public.events;
create policy "anyone reads events" on public.events for select
  using ((cat <> 'officer_meeting' and not draft) or is_officer());
