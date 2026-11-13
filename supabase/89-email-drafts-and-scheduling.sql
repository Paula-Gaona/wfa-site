-- WFA update: the email builder can save drafts and schedule emails. Officers share one list of drafts and scheduled
-- emails (Officer tools -> Email). A scheduled email is prepared when it's scheduled (one email per person, so
-- newsletters keep each person's picks) and sent by the auto-emails function, which runs every 10 minutes, so it goes
-- out within about 10 minutes of the chosen time. Cancel or edit it any time before then.
-- Needs the updated auto-emails function (Supabase -> Edge Functions -> auto-emails -> paste -> Deploy).
-- Run once in Supabase -> SQL Editor. Safe to run again.

create table if not exists public.email_drafts (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  created_by text not null default public.jwt_email(),
  updated_at timestamptz not null default now(),
  updated_by text not null default public.jwt_email(),
  subject text not null default '' check (char_length(subject) <= 300),
  data jsonb not null default '{}',                -- everything in the builder (audience, message, events, layout, ...)
  status text not null default 'draft' check (status in ('draft', 'scheduled', 'sending', 'sent', 'failed')),
  send_at timestamptz,
  sent_at timestamptz,
  recipients int not null default 0,
  sent_count int not null default 0,
  detail text not null default ''
);
alter table public.email_drafts enable row level security;
drop policy if exists "officers manage email drafts" on public.email_drafts;
create policy "officers manage email drafts" on public.email_drafts for all using (is_officer()) with check (is_officer());
grant select, insert, update, delete on public.email_drafts to authenticated;

-- The prepared emails of a scheduled send, one row per person.
create table if not exists public.email_outbox (
  id bigint generated always as identity primary key,
  draft_id uuid not null references public.email_drafts (id) on delete cascade,
  to_email text not null,
  subject text not null,
  text text not null,
  html text not null,
  check_opt_out boolean not null default true,   -- skip people who turned off club emails (not for officer-team emails)
  sent_at timestamptz,
  error text
);
create index if not exists email_outbox_draft on public.email_outbox (draft_id) where sent_at is null;
alter table public.email_outbox enable row level security;
drop policy if exists "officers manage the outbox" on public.email_outbox;
create policy "officers manage the outbox" on public.email_outbox for all using (is_officer()) with check (is_officer());
grant select, insert, delete on public.email_outbox to authenticated;
