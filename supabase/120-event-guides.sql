-- WFA update: what each event's guide saves.
-- One row per event, for officers only: the guest or panelist list (who was asked, who confirmed, what they've sent,
-- the speaking order), the panel schedule (how many panelists, any times changed by hand), and which guest emails
-- have gone out to whom. Kept apart from the event itself so any officer can update it after the event is posted.
-- Run once in Supabase -> SQL Editor. Safe to run again.

create table if not exists public.event_guides (
  event_id uuid primary key references public.events(id) on delete cascade,
  data jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object'),
  updated_by text not null default '',
  updated_at timestamptz not null default now()
);
alter table public.event_guides enable row level security;
drop policy if exists "officers read event guides" on public.event_guides;
create policy "officers read event guides" on public.event_guides for select using (is_officer());
drop policy if exists "officers add event guides" on public.event_guides;
create policy "officers add event guides" on public.event_guides for insert with check (is_officer());
drop policy if exists "officers edit event guides" on public.event_guides;
create policy "officers edit event guides" on public.event_guides for update using (is_officer()) with check (is_officer());
drop policy if exists "officers delete event guides" on public.event_guides;
create policy "officers delete event guides" on public.event_guides for delete using (is_officer());
grant select, insert, update, delete on public.event_guides to authenticated;
grant select, insert, update, delete on public.event_guides to service_role;
