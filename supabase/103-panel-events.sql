-- WFA update: "Panel" is its own event type. It works like a guest speaker event: 15 points, Q&A, outside guests,
-- and the presidents approve it before it's published.
-- Run once in Supabase -> SQL Editor, after 102. Safe to run again.

alter table public.events drop constraint if exists events_cat_check;
alter table public.events add constraint events_cat_check check (cat in
  ('case_competition', 'career_fair', 'guest_speaker', 'panel', 'excursion', 'workshop', 'social', 'officer_meeting'));

create or replace function public.event_points(c text) returns int
language sql immutable as $$
  select case c
    when 'case_competition' then 25 when 'career_fair' then 25 when 'excursion' then 25
    when 'guest_speaker' then 15 when 'panel' then 15 when 'workshop' then 10 when 'social' then 10
    else 0 end
$$;

create or replace function public.big_event(p_cat text) returns boolean
language sql immutable as $$ select p_cat in ('case_competition', 'excursion', 'guest_speaker', 'panel', 'career_fair'); $$;
