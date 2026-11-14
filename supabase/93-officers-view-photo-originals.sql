-- WFA update: the site reads officer profiles through the officers_public view, which was made before the original
-- photo and crop columns existed (92-profile-photo-originals.sql), so "Adjust crop" couldn't find the original.
-- This rebuilds the view (same as 27-approvals.sql) so it includes them. Run once in Supabase -> SQL Editor, after 92.
-- Safe to run again.

drop view if exists public.officers_public;
create view public.officers_public as
  select p.*, a.role,
    coalesce(m.majors, '{}') as majors,
    coalesce(m.minor, '') as minor
  from public.officer_profiles p
  join public.access_list a using (email)
  left join public.members m on m.email = p.email;
grant select on public.officers_public to anon, authenticated;
