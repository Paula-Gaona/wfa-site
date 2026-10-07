-- WFA update: let admins remove members, and give officers profile pictures.
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

-- ============ Officer profile pictures ============
alter table public.officer_profiles add column if not exists photo text not null default '';

drop view if exists public.officers_public;
create view public.officers_public as
  select p.*, a.role from public.officer_profiles p join public.access_list a using (email);
grant select on public.officers_public to anon, authenticated;

insert into storage.buckets (id, name, public) values ('officer-photos', 'officer-photos', true)
  on conflict (id) do nothing;
create policy "officers upload profile photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'officer-photos' and public.is_officer());
create policy "officers delete profile photos" on storage.objects for delete to authenticated
  using (bucket_id = 'officer-photos' and public.is_officer());
