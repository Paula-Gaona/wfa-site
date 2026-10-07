-- WFA update: let admins remove members.
-- Paste into Supabase -> SQL Editor -> New query, then Run.

create or replace function public.remove_member(p_email text) returns text
language plpgsql security definer set search_path = public as $$
declare e text := lower(trim(p_email)); uid uuid;
begin
  if not is_admin() then raise exception 'Only admins can remove members.'; end if;
  if e = jwt_email() then raise exception 'You can''t remove your own account.'; end if;

  -- Officer access first: the last-admin guard stops this if they are the only admin.
  delete from access_list where email = e;
  delete from officer_profiles where email = e;
  delete from rsvps where email = e;
  delete from attendance where email = e;
  delete from dues where email = e;

  -- Deleting the login also deletes their member row.
  select id into uid from members where email = e;
  if uid is not null then delete from auth.users where id = uid; end if;

  insert into change_log (who, text) values (jwt_email(), 'Removed member ' || e);
  return 'ok';
end $$;
