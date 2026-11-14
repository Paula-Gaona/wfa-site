-- WFA update: profile pictures keep the original photo and where it was cropped, so "Adjust crop" always starts from
-- the full original (not the already-cropped picture). Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.officer_profiles add column if not exists photo_original text not null default '';
alter table public.officer_profiles add column if not exists photo_crop jsonb not null default '{}';
