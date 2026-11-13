-- WFA update: a standard newsletter intro. It fills in the message when someone starts a newsletter in the email
-- builder (they can still change it for that week). Leadership can save a new standard intro from the builder.
-- Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.settings add column if not exists newsletter_intro text not null default '';
