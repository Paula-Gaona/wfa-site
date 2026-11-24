-- WFA update: confirmed guests show on the event page by themselves.
-- On an event's guide, marking a guest speaker or panelist as confirmed (or un-confirming, editing, reordering, or
-- removing one) now updates the event page's guest list straight away. Any officer can do this, including on an
-- event that's already posted, because only people marked confirmed are ever shown.
-- Run once in Supabase -> SQL Editor, after 120-event-guides.sql. Safe to run again.

create or replace function public.guide_sync_speakers(p_event uuid) returns text
language plpgsql security definer set search_path = public as $$
declare ev events; g jsonb; sp jsonb;
begin
  if not public.is_officer() then return 'err:notofficer'; end if;
  select * into ev from events where id = p_event;
  if ev.id is null then return 'err:missing'; end if;
  if ev.cat not in ('guest_speaker', 'panel') then return 'err:state'; end if;
  select data into g from event_guides where event_id = p_event;
  -- The confirmed people, in the guide's order. Anything already on the event for the same name (a bio, say) is kept.
  select coalesce(jsonb_agg(
           coalesce((select o from jsonb_array_elements(coalesce(ev.speakers, '[]'::jsonb)) o where o->>'name' = n.nm limit 1), '{}'::jsonb)
           || jsonb_strip_nulls(jsonb_build_object('name', n.nm, 'title', nullif(t.p->>'title', ''), 'company', nullif(t.p->>'company', ''), 'field', nullif(t.p->>'field', '')))
           order by t.ord), '[]'::jsonb) into sp
    from jsonb_array_elements(coalesce(g->'people', '[]'::jsonb)) with ordinality t(p, ord)
      cross join lateral (select trim(concat_ws(' ', nullif(t.p->>'first', ''), nullif(t.p->>'last', ''))) as nm) n
    where t.p->>'status' = 'confirmed' and n.nm <> '';
  update events set speakers = sp where id = p_event;
  return 'ok';
end $$;
revoke execute on function public.guide_sync_speakers(uuid) from public, anon;
grant execute on function public.guide_sync_speakers(uuid) to authenticated;
