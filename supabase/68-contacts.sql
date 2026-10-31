-- WFA update: Contacts (Officer tools -> Planning events -> Contacts). One list of the industry professionals, firms,
-- and faculty the club works with or wants to: who owns each contact, where outreach stands, which kinds of events
-- they're interested in, when works for them, and the event they're confirmed for. Leadership sets how many of each
-- kind of event to hold this semester (the semester plan), and the page shows how many are confirmed so far.
-- Partner with us inquiries are added automatically. Officers only: it has outside people's contact details.
-- Run once in Supabase -> SQL Editor. Safe to run again.

create table if not exists public.contacts (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  created_by text not null default coalesce(public.jwt_email(), ''),
  updated_at timestamptz not null default now(),
  kind text not null default 'professional' check (kind in ('professional', 'firm', 'faculty')),
  name text not null default '' check (char_length(name) <= 120),
  org text not null default '' check (char_length(org) <= 160),        -- firm, or department for faculty
  title text not null default '' check (char_length(title) <= 160),
  email text not null default '' check (char_length(email) <= 254),
  phone text not null default '' check (char_length(phone) <= 40),
  linkedin text not null default '' check (char_length(linkedin) <= 300),
  preferred text not null default '' check (char_length(preferred) <= 60),   -- how they like to be reached
  owner text not null default '',                                     -- the officer handling outreach
  status text not null default 'prospect'
    check (status in ('prospect', 'contacted', 'interested', 'confirmed', 'done', 'no_response', 'declined')),
  types text[] not null default '{}' check (cardinality(types) <= 12),  -- event types they're interested in or considered for
  areas text[] not null default '{}' check (cardinality(areas) <= 30),  -- career areas they can speak to
  availability jsonb check (availability is null or (jsonb_typeof(availability) = 'object' and octet_length(availability::text) <= 2000)),
  planned_date date,                                                   -- once a specific date is settled
  confirmed_cat text not null default '',                              -- which kind of event they're confirmed for
  event_id uuid references public.events (id) on delete set null,
  semester text not null default '',
  last_contacted date,
  would_return text not null default '' check (would_return in ('', 'yes', 'maybe', 'no')),
  notes text not null default '' check (char_length(notes) <= 8000),
  source text not null default 'officer' check (source in ('officer', 'partner_form')),
  question_id uuid unique references public.questions (id) on delete set null
);
alter table public.contacts enable row level security;
drop policy if exists "officers manage contacts" on public.contacts;
create policy "officers manage contacts" on public.contacts for all using (public.is_officer()) with check (public.is_officer());
grant select, insert, update, delete on public.contacts to authenticated;
grant select, insert, update, delete on public.contacts to service_role;
-- Different details for each kind of contact: the specific ways they could help (the same choices as the Partner with
-- us form, plus a faculty list), and the courses a faculty member teaches. For a firm, "areas" are the finance areas it
-- works in; for a person, the areas they can speak to.
alter table public.contacts add column if not exists ways text[] not null default '{}';
alter table public.contacts add column if not exists courses text not null default '';
alter table public.contacts add column if not exists call_time text not null default '' check (char_length(call_time) <= 120);   -- best time to call, when they prefer phone calls
alter table public.contacts drop constraint if exists contacts_extra_len;
alter table public.contacts add constraint contacts_extra_len check (cardinality(ways) <= 20 and char_length(courses) <= 500);

-- The semester plan: how many of each kind of event leadership wants this semester (no topics or months, on purpose).
create table if not exists public.outreach_plan (
  semester text not null,
  cat text not null,
  target int not null default 0 check (target between 0 and 50),
  primary key (semester, cat)
);
alter table public.outreach_plan enable row level security;
drop policy if exists "officers read the plan" on public.outreach_plan;
create policy "officers read the plan" on public.outreach_plan for select using (public.is_officer());
drop policy if exists "leadership writes the plan" on public.outreach_plan;
create policy "leadership writes the plan" on public.outreach_plan for all
  using (public.is_admin() or exists (select 1 from public.officer_profiles o where o.email = public.jwt_email() and o.tier in ('president', 'vice_president', 'advisor')))
  with check (public.is_admin() or exists (select 1 from public.officer_profiles o where o.email = public.jwt_email() and o.tier in ('president', 'vice_president', 'advisor')));
grant select, insert, update, delete on public.outreach_plan to authenticated;

-- The Partner with us form asks how they'd like to be reached (Email, LinkedIn, Phone or text, Microsoft Teams),
-- and their LinkedIn profile or phone number when that's what they picked.
alter table public.questions add column if not exists preferred text not null default '';
alter table public.questions add column if not exists phone text not null default '';
alter table public.questions add column if not exists linkedin text not null default '';
alter table public.questions add column if not exists call_time text not null default '' check (char_length(call_time) <= 120);
alter table public.questions drop constraint if exists questions_reach_len;
alter table public.questions add constraint questions_reach_len
  check (char_length(preferred) <= 60 and char_length(phone) <= 40 and char_length(linkedin) <= 300);
-- A partner who'd rather be reached by phone or LinkedIn doesn't have to give an email. Anything given must be valid.
alter table public.questions drop constraint if exists questions_email_check;
alter table public.questions drop constraint if exists questions_email_ok;
alter table public.questions add constraint questions_email_ok check (
  (char_length(email) between 5 and 254 and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')
  or (kind = 'partner' and email = '' and (phone <> '' or linkedin <> '')));
alter table public.questions drop constraint if exists questions_phone_ok;
alter table public.questions add constraint questions_phone_ok check (phone = '' or phone ~ '^[0-9+() .-]{10,20}$');
alter table public.questions drop constraint if exists questions_linkedin_ok;
alter table public.questions add constraint questions_linkedin_ok check (linkedin = '' or linkedin ~* '^https://www\.linkedin\.com/(in|company)/[^\s/?#]+/?$');

-- Partner with us inquiries become contacts (already "interested", since they reached out).
create or replace function public.contact_from_partner(q public.questions) returns void
language plpgsql security definer set search_path = public as $$
declare t text[] := '{}'; w text;
begin
  if q.kind <> 'partner' then return; end if;
  foreach w in array coalesce(q.ways, '{}') loop
    t := t || case
      when w ilike 'Guest speaker%' then 'guest_speaker'
      when w ilike '%workshop%' then 'workshop'
      when w ilike '%case%' then 'case_competition'
      when w ilike 'Career fairs%' or w ilike 'Info session%' then 'career_fair'
      when w ilike 'Office visit%' then 'excursion'
      else null end;
  end loop;
  insert into contacts (created_by, kind, name, org, title, email, phone, linkedin, call_time, preferred, status, types, ways, areas, availability, semester, notes, source, question_id)
  values ('partner form', case when q.topic = 'Firm or organization' then 'firm' else 'professional' end,
    left(coalesce(q.name, ''), 120), left(coalesce(q.company, ''), 160), left(coalesce(q.job_title, ''), 160), left(q.email, 254), left(coalesce(q.phone, ''), 40), left(coalesce(q.linkedin, ''), 300), left(coalesce(q.call_time, ''), 120), coalesce(nullif(q.preferred, ''), 'Email'),
    'interested', (select coalesce(array_agg(distinct x), '{}') from unnest(t) x where x is not null), coalesce(q.ways, '{}'), coalesce(q.functions, '{}'), q.availability,
    coalesce((select s.semester from settings s where s.id = 1), ''),
    left('From the Partner with us form (' || to_char(q.created_at at time zone 'America/Denver', 'Mon DD, YYYY') || ').'
      || case when cardinality(coalesce(q.ways, '{}')) > 0 then E'\nInterested in: ' || array_to_string(q.ways, ', ') else '' end
      || E'\n' || q.message, 8000),
    'partner_form', q.id)
  on conflict (question_id) do nothing;
end $$;
revoke execute on function public.contact_from_partner(public.questions) from public, anon, authenticated;

create or replace function public.partner_to_contact() returns trigger
language plpgsql security definer set search_path = public as $$
begin perform public.contact_from_partner(new); return new; end $$;
drop trigger if exists partner_to_contact on public.questions;
create trigger partner_to_contact after insert on public.questions for each row execute function public.partner_to_contact();

-- Add the partner inquiries that came in before this.
select public.contact_from_partner(q) from public.questions q where q.kind = 'partner';
