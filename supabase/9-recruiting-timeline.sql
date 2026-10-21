-- WFA update: officers can edit the recruiting timeline on the Resources page.
-- Paste into Supabase -> SQL Editor -> New query, then Run.

create table public.recruiting_timeline (
  id uuid primary key default gen_random_uuid(),
  when_text text not null,
  what_text text not null,
  sort int not null default 0
);
alter table public.recruiting_timeline enable row level security;
create policy "anyone reads the timeline" on public.recruiting_timeline for select using (true);
create policy "officers add timeline rows" on public.recruiting_timeline for insert with check (is_officer());
create policy "officers edit timeline rows" on public.recruiting_timeline for update using (is_officer());
create policy "officers delete timeline rows" on public.recruiting_timeline for delete using (is_officer());

-- The rows that were on the page before.
insert into public.recruiting_timeline (when_text, what_text, sort) values
  ('Freshman / sophomore year', 'Attend workshops, learn Excel and accounting basics, apply to sophomore insight programs.', 0),
  ('Spring of sophomore year', 'Many banks open junior summer internship applications well over a year ahead. Have your résumé ready.', 1),
  ('Junior summer', 'Internship. A strong summer often leads to a full-time return offer.', 2),
  ('Senior fall', 'Full-time recruiting for anyone without a return offer.', 3);
