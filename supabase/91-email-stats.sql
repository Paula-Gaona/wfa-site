-- WFA update: email statistics. Resend (the email service) reports when each club email is delivered, opened,
-- clicked, or bounces, to the email-events Edge Function, which saves the reports here. The email builder's
-- "Recently sent" list shows the totals for each email. Each email carries a "campaign" label: the id of its
-- draft in email_drafts (89-email-drafts-and-scheduling.sql).
-- Run once in Supabase -> SQL Editor. Safe to run again.

create table if not exists public.email_events (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  type text not null,                 -- delivered, opened, clicked, bounced, complained, delivery_delayed
  email_id text not null,             -- Resend's id for the email
  to_email text not null default '',
  campaign text not null default '',  -- the email_drafts id it came from
  link text not null default ''       -- for clicks: which link
);
-- One row per email, kind of event, and link (opening an email five times counts once).
create unique index if not exists email_events_once on public.email_events (email_id, type, link);
create index if not exists email_events_campaign on public.email_events (campaign);
alter table public.email_events enable row level security;
drop policy if exists "officers read email events" on public.email_events;
create policy "officers read email events" on public.email_events for select using (is_officer());
grant select on public.email_events to authenticated;
grant select, insert on public.email_events to service_role;

-- Totals per email for the email builder (officers only): emails delivered, opened, clicked, and bounced.
create or replace function public.email_stats() returns table (campaign text, delivered int, opened int, clicked int, bounced int)
language sql stable security definer set search_path = public as $$
  select e.campaign,
    count(distinct e.email_id) filter (where e.type = 'delivered')::int,
    count(distinct e.email_id) filter (where e.type = 'opened')::int,
    count(distinct e.email_id) filter (where e.type = 'clicked')::int,
    count(distinct e.email_id) filter (where e.type in ('bounced', 'complained'))::int
  from email_events e where e.campaign <> '' and public.is_officer() group by e.campaign
$$;
revoke execute on function public.email_stats() from public, anon;
grant execute on function public.email_stats() to authenticated;
