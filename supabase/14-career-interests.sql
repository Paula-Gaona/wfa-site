-- WFA update: career interests on member profiles.
-- Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.members add column if not exists interests text[] not null default '{}';

-- New accounts: save the career interests picked on the sign-up form.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare m text[]; i text[];
begin
  if jsonb_typeof(new.raw_user_meta_data -> 'majors') = 'array' then
    m := array(select jsonb_array_elements_text(new.raw_user_meta_data -> 'majors'));
  elsif coalesce(new.raw_user_meta_data ->> 'major', '') <> '' then
    m := array[new.raw_user_meta_data ->> 'major'];
  else
    m := '{}';
  end if;
  if jsonb_typeof(new.raw_user_meta_data -> 'interests') = 'array' then
    i := array(select jsonb_array_elements_text(new.raw_user_meta_data -> 'interests'));
  else
    i := '{}';
  end if;
  insert into members (id, email, uvuid, first, last, major, majors, minor, interests)
  values (new.id, lower(new.email),
          coalesce(new.raw_user_meta_data ->> 'uvuid', ''),
          coalesce(new.raw_user_meta_data ->> 'first', ''),
          coalesce(new.raw_user_meta_data ->> 'last', ''),
          coalesce(m[1], ''), m,
          coalesce(new.raw_user_meta_data ->> 'minor', ''),
          i);
  return new;
end $$;
