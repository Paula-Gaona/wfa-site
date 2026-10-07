-- WFA fix: allow the Vice President rank (and the other ranks) on officer profiles.
alter table public.officer_profiles drop constraint if exists officer_profiles_tier_check;
alter table public.officer_profiles add constraint officer_profiles_tier_check
  check (tier in ('president', 'vice_president', 'advisor', 'officer', 'honorary'));
