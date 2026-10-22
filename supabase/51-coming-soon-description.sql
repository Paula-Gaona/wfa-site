-- WFA update: coming-soon pages get their own short description (the draft's date and details stay hidden), and
-- nobody can RSVP to a draft. Run once in Supabase -> SQL Editor, after 50. Safe to run again.

alter table public.events add column if not exists soon_desc text not null default '';

create or replace function public.event_coming_soon(p_id uuid) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('title', e.title, 'desc', e.soon_desc) from events e where e.id = p_id and e.draft and e.coming_soon;
$$;
grant execute on function public.event_coming_soon(uuid) to anon, authenticated;

-- Only people who can publish change the coming-soon page or its description.
create or replace function public.guard_coming_soon() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.can_publish() or auth.uid() is null then return new; end if;
  if tg_op = 'INSERT' then new.coming_soon := false; new.soon_desc := '';
  else new.coming_soon := old.coming_soon; new.soon_desc := old.soon_desc; end if;
  return new;
end $$;

-- No RSVPs to drafts.
create or replace function public.no_draft_rsvps() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from events e where e.id = new.event_id and e.draft) then
    raise exception 'RSVPs open when the event is published.';
  end if;
  return new;
end $$;
drop trigger if exists no_draft_rsvps on public.rsvps;
create trigger no_draft_rsvps before insert on public.rsvps for each row execute function public.no_draft_rsvps();
