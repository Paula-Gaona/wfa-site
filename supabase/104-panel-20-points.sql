-- WFA update: panels are worth 20 points. Run once in Supabase -> SQL Editor, after 103. Safe to run again.
create or replace function public.event_points(c text) returns int
language sql immutable as $$
  select case c
    when 'case_competition' then 25 when 'career_fair' then 25 when 'excursion' then 25
    when 'panel' then 20 when 'guest_speaker' then 15 when 'workshop' then 10 when 'social' then 10
    else 0 end
$$;
