-- WFA update: a dress code on each event (casual, business casual, business professional, ...) plus an optional note,
-- like "Bring a jacket; part of the tour is outside". Empty means no dress code is shown.
-- Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.events add column if not exists dress_code text not null default '';
alter table public.events add column if not exists dress_note text not null default '';
alter table public.events drop constraint if exists events_dress_code_ok;
alter table public.events add constraint events_dress_code_ok check (dress_code in
  ('', 'casual', 'smart_casual', 'business_casual', 'business_professional', 'semi_formal', 'outdoor'));
alter table public.events drop constraint if exists events_dress_note_len;
alter table public.events add constraint events_dress_note_len check (char_length(dress_note) <= 200);
