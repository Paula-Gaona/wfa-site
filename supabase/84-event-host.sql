-- WFA update: mark events that another organization hosts and WFA is only advertising ("Hosted by ..." on the event).
-- Empty means WFA hosts it. Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.events add column if not exists host text not null default '';
alter table public.events drop constraint if exists events_host_len;
alter table public.events add constraint events_host_len check (char_length(host) <= 120);
