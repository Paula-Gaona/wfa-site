-- WFA update: the Partner with us form asks when works best (months, days, and times of day, all optional).
-- Officers see it on the inquiry in Officer tools -> Questions. Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.questions add column if not exists availability jsonb;
alter table public.questions drop constraint if exists questions_availability_size;
alter table public.questions add constraint questions_availability_size
  check (availability is null or (jsonb_typeof(availability) = 'object' and octet_length(availability::text) <= 2000));
