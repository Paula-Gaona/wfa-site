-- WFA update: officers can add and delete links on the Resources page.
-- Paste into Supabase -> SQL Editor -> New query, then Run.

create table public.resources (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  descr text not null default '',
  url text not null,
  created_at timestamptz not null default now()
);
alter table public.resources enable row level security;
create policy "anyone reads resources" on public.resources for select using (true);
create policy "officers add resources" on public.resources for insert with check (is_officer());
create policy "officers edit resources" on public.resources for update using (is_officer());
create policy "officers delete resources" on public.resources for delete using (is_officer());

-- The links that were on the page before, in the same order.
insert into public.resources (title, descr, url, created_at) values
  ('SEC EDGAR full-text search', 'Primary source for 10-Ks, 10-Qs, and proxy statements when you build a pitch.', 'https://www.sec.gov/edgar/search/', now()),
  ('FRED economic data', 'Federal Reserve data on rates, inflation, and employment for macro context.', 'https://fred.stlouisfed.org/', now() + interval '1 second'),
  ('Damodaran Online', 'Free valuation datasets and lecture notes from NYU professor Aswath Damodaran.', 'https://pages.stern.nyu.edu/~adamodar/', now() + interval '2 seconds'),
  ('CFA Institute', 'Program details for the CFA charter and the Research Challenge.', 'https://www.cfainstitute.org/', now() + interval '3 seconds'),
  ('Investopedia', 'Quick definitions when a term in a speaker talk is new to you.', 'https://www.investopedia.com/', now() + interval '4 seconds');
