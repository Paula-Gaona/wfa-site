-- Permanently remove every account AND clear the officer list, except paula.gaona@uvu.edu (stays admin).
-- Keeps events, announcements, recaps, resources, careers, timeline, tasks, and the change log.
begin;

do $$
begin
  if not exists (select 1 from auth.users where lower(email) = 'paula.gaona@uvu.edu') then
    raise exception 'Stopped: the paula.gaona@uvu.edu account was not found, so nothing was deleted.';
  end if;
  if not exists (select 1 from public.access_list where email = 'paula.gaona@uvu.edu' and role = 'admin') then
    raise exception 'Stopped: paula.gaona@uvu.edu is not an admin, so nothing was deleted.';
  end if;
end $$;

-- Officer list and Officers-page profiles.
delete from public.access_list      where email <> 'paula.gaona@uvu.edu';
delete from public.officer_profiles where email <> 'paula.gaona@uvu.edu';
-- Personal records tied to the removed accounts.
delete from public.rsvps        where email <> 'paula.gaona@uvu.edu';
delete from public.attendance   where email <> 'paula.gaona@uvu.edu';
delete from public.dues         where email <> 'paula.gaona@uvu.edu';
delete from public.applications where email <> 'paula.gaona@uvu.edu';
delete from public.availability where email <> 'paula.gaona@uvu.edu';
-- The logins themselves (member rows go with them automatically).
delete from auth.users where lower(email) <> 'paula.gaona@uvu.edu';

insert into public.change_log (who, text) values ('paula.gaona@uvu.edu', 'Removed all accounts and cleared the officer list except paula.gaona@uvu.edu');

commit;

-- Check: both lists should show only paula.gaona@uvu.edu
select 'account' as kind, email from auth.users
union all select 'officer list (' || role || ')', email from public.access_list;
