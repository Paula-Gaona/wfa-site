-- WFA update: more than one officer can handle a contact (Officer tools -> Contacts -> "Handled by", a multi-pick
-- dropdown). The old single owner is copied into the list, and stays as the first officer on it.
-- Run once in Supabase -> SQL Editor, after 68-contacts.sql. Safe to run again.

alter table public.contacts add column if not exists owners text[] not null default '{}';
alter table public.contacts drop constraint if exists contacts_owners_len;
alter table public.contacts add constraint contacts_owners_len check (cardinality(owners) <= 20);
update public.contacts set owners = array[owner] where owner <> '' and cardinality(owners) = 0;
