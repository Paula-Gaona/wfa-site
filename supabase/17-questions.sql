-- WFA update: "Ask a question" contact form.
-- Anyone (signed in or not) can send a question. Only officers and admins can read,
-- update, or delete them. Run once in Supabase -> SQL Editor. Safe to run again.

create table if not exists public.questions (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  name text not null default '' check (char_length(name) <= 120),
  email text not null check (char_length(email) between 5 and 254 and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  topic text not null default 'Other' check (char_length(topic) <= 60),
  message text not null check (char_length(message) between 1 and 5000),
  status text not null default 'new' check (status in ('new', 'answered')),
  answered_by text not null default '',
  answered_at timestamptz
);

alter table public.questions enable row level security;

drop policy if exists "anyone sends a question" on public.questions;
create policy "anyone sends a question" on public.questions for insert to anon, authenticated
  with check (status = 'new' and answered_by = '' and answered_at is null);

drop policy if exists "officers read questions" on public.questions;
create policy "officers read questions" on public.questions for select using (is_officer());

drop policy if exists "officers update questions" on public.questions;
create policy "officers update questions" on public.questions for update using (is_officer());

drop policy if exists "officers delete questions" on public.questions;
create policy "officers delete questions" on public.questions for delete using (is_officer());

grant insert on public.questions to anon, authenticated;
grant select, update, delete on public.questions to authenticated;
