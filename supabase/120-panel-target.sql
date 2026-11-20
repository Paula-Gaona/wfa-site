-- WFA update: how many panelists a panel is aiming for.
-- The panel guide sizes the two-hour schedule (talk length, host questions, live questions) to this number.
-- Officers set it on the guide page. Empty means the guide goes by the panelists listed on the event.
-- Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.events add column if not exists panel_target smallint;
