-- WFA update: editable About page. Officers edit it on the site; until then the built-in text shows.
-- Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.settings add column if not exists about jsonb not null default '{}'::jsonb;
