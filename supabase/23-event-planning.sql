-- WFA update: planning notes for each event (Officer tools > Event planning).
-- The checklist itself uses the existing tasks table. Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.events add column if not exists plan_notes text not null default '';
