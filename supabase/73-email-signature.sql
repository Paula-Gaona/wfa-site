-- WFA update: officers can save their own email signature (Officer tools -> Email builder -> Edit my signature).
-- Blank means the built-in one, filled in from their officer profile. Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.officer_profiles add column if not exists signature text not null default '';
alter table public.officer_profiles drop constraint if exists officer_profiles_signature_len;
alter table public.officer_profiles add constraint officer_profiles_signature_len check (char_length(signature) <= 2000);
