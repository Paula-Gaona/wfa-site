-- WFA update: officers can hide an event's RSVP count from members and guests ("Show how many people RSVP'd" in the
-- event form). On by default, so every existing event keeps showing its count. Officers always see it.
-- Run once in Supabase -> SQL Editor. Safe to run again.
alter table public.events add column if not exists show_rsvps boolean not null default true;
