-- WFA update: for events run by another organization (a registration link), record which members clicked "Register".
-- One row per member per event, so clicking twice still counts once. Officers see the count and names on the event.
-- Only signed-in members are recorded. Run once in Supabase -> SQL Editor, after 116. Safe to run again.

create table if not exists public.event_link_clicks (
  event_id uuid not null references public.events(id) on delete cascade,
  email text not null,
  clicked_at timestamptz not null default now(),
  primary key (event_id, email)
);
alter table public.event_link_clicks enable row level security;
drop policy if exists "officers read link clicks" on public.event_link_clicks;
create policy "officers read link clicks" on public.event_link_clicks for select using (public.is_officer());
grant select on public.event_link_clicks to authenticated;
grant select, insert, update, delete on public.event_link_clicks to service_role;

create or replace function public.log_link_click(p_event uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me text := public.jwt_email();
begin
  if auth.uid() is null or me is null then return; end if;
  if not exists (select 1 from events where id = p_event and reg_mode = 'link') then return; end if;
  insert into event_link_clicks (event_id, email) values (p_event, me) on conflict do nothing;
end $$;
grant execute on function public.log_link_click(uuid) to authenticated;
