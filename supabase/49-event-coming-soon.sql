-- WFA update: drafts can have a coming-soon page. Officers can copy a draft's link or QR code ahead of time; if the
-- draft has "Coming-soon page" checked, anyone who opens the link before it's published sees only the title and
-- "coming soon" (nothing else about the draft). Run once in Supabase -> SQL Editor, after 48. Safe to run again.

alter table public.events add column if not exists coming_soon boolean not null default false;

create or replace function public.event_coming_soon(p_id uuid) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('title', e.title) from events e where e.id = p_id and e.draft and e.coming_soon;
$$;
grant execute on function public.event_coming_soon(uuid) to anon, authenticated;
