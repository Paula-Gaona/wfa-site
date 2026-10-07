-- WFA update: show officers' majors and minor on the public Officers page.
-- Paste into Supabase -> SQL Editor -> New query, then Run.
-- Only officers' majors and minor are shared; other member details stay private.

drop view if exists public.officers_public;
create view public.officers_public as
  select p.*, a.role,
    coalesce(m.majors, '{}') as majors,
    coalesce(m.minor, '') as minor
  from public.officer_profiles p
  join public.access_list a using (email)
  left join public.members m on m.email = p.email;
grant select on public.officers_public to anon, authenticated;

-- Leaderboard: separate multiple majors with " & " (degree names already contain commas).
create or replace function public.leaderboard()
returns table (email text, first text, last text, major text, events int, points int)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  return query
    select case when m.email = jwt_email() then m.email else null end,
      m.first, m.last, array_to_string(m.majors, ' & '),
      count(e.id)::int,
      coalesce(sum(event_points(e.cat)), 0)::int
    from members m
    left join attendance a on a.email = m.email
    left join events e on e.id = a.event_id and e.cat <> 'officer_meeting'
    where not exists (select 1 from access_list al where al.email = m.email)
    group by m.email, m.first, m.last, m.majors;
end $$;
