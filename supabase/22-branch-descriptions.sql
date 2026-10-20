-- WFA update: editable descriptions of each officer branch, shown on the Apply page.
-- Admins edit them on the site. Until then, the site shows built-in defaults.
-- Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.app_settings add column if not exists branch_info jsonb not null default '{}'::jsonb;
