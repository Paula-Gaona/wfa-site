-- WFA update: tailored resumes for each firm type (Private Equity, Corporate development, ...).
-- Run once in Supabase -> SQL Editor, after 19-resume-book.sql. Safe to run again.
-- A member's general resume stays in members.resume_path. Tailored ones go here, one per firm type.

create table if not exists public.member_resumes (
  member_id uuid not null references public.members (id) on delete cascade,
  category text not null check (char_length(category) between 1 and 80),
  path text not null,
  updated_at timestamptz not null default now(),
  primary key (member_id, category)
);

alter table public.member_resumes enable row level security;

-- Members manage their own. Officers can see them only for members in the resume book.
drop policy if exists "own or officers read tailored resumes" on public.member_resumes;
create policy "own or officers read tailored resumes" on public.member_resumes for select
  using (member_id = auth.uid()
         or (public.is_officer() and exists (select 1 from public.members m where m.id = member_id and m.resume_book)));
drop policy if exists "members add own tailored resumes" on public.member_resumes;
create policy "members add own tailored resumes" on public.member_resumes for insert with check (member_id = auth.uid());
drop policy if exists "members update own tailored resumes" on public.member_resumes;
create policy "members update own tailored resumes" on public.member_resumes for update using (member_id = auth.uid());
drop policy if exists "members delete own tailored resumes" on public.member_resumes;
create policy "members delete own tailored resumes" on public.member_resumes for delete using (member_id = auth.uid());
grant select, insert, update, delete on public.member_resumes to authenticated;

-- Partner form: the finance functions a firm works in, used to pick the right resume book.
alter table public.questions add column if not exists functions text[] not null default '{}';
alter table public.questions drop constraint if exists questions_functions_len;
alter table public.questions add constraint questions_functions_len check (cardinality(functions) <= 30);

-- Officers can open a tailored resume file only if that member opted in to the resume book.
drop policy if exists "officers read tailored resume files" on storage.objects;
create policy "officers read tailored resume files" on storage.objects for select to authenticated
  using (
    bucket_id = 'resumes' and public.is_officer()
    and exists (select 1 from public.member_resumes r join public.members m on m.id = r.member_id
                where r.path = storage.objects.name and m.resume_book)
  );
