-- WFA update: only people who can publish events (presidents, vice presidents, the faculty advisor, admins, and
-- officers given publishing rights) can turn a draft's coming-soon page on or off. Anyone else's change to it is
-- ignored. Run once in Supabase -> SQL Editor, after 49. Safe to run again.

create or replace function public.guard_coming_soon() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.can_publish() or auth.uid() is null then return new; end if;
  if tg_op = 'INSERT' then new.coming_soon := false;
  else new.coming_soon := old.coming_soon; end if;
  return new;
end $$;
drop trigger if exists guard_coming_soon on public.events;
create trigger guard_coming_soon before insert or update on public.events
  for each row execute function public.guard_coming_soon();
