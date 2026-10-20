-- WFA update: member resumes and the resume book.
-- Members upload a PDF resume in My account and choose whether to be in the resume book.
-- Officers can open a resume only if that member opted in. Run once in Supabase -> SQL Editor.
-- Safe to run again.

alter table public.members add column if not exists resume_path text not null default '';
alter table public.members add column if not exists resume_book boolean not null default false;
alter table public.members add column if not exists resume_updated timestamptz;

-- Resumes live in the existing private "resumes" bucket, in each member's own folder.
-- Members can already upload, open, and delete files in their own folder (7-applications-availability.sql).
drop policy if exists "officers read resume book" on storage.objects;
create policy "officers read resume book" on storage.objects for select to authenticated
  using (
    bucket_id = 'resumes' and public.is_officer()
    and exists (select 1 from public.members m where m.resume_path = storage.objects.name and m.resume_book)
  );
