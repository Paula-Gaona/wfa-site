-- WFA update: remembers when a survey was emailed to members (the "Email it to members" box in the survey builder),
-- so the builder can say so. Run once in Supabase -> SQL Editor. Safe to run again.
alter table public.surveys add column if not exists emailed_at timestamptz;
