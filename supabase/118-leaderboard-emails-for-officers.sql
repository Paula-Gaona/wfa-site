-- WFA update: the leaderboard tells officers which account each row is, so they can open a member's account from it.
-- Members still only get their own. Same as 33-test-accounts.sql otherwise.
-- Run once in Supabase -> SQL Editor, after 117. Safe to run again.

create or replace function public.leaderboard()
returns table (email text, first text, last text, major text, events int, points int, anon boolean)
language plpgsql stable security definer set search_path = public as $$
declare since timestamptz;
begin
  if auth.uid() is null then return; end if;
  select lb_since into since from settings where id = 1;
  return query
    select case when s.email = jwt_email() or is_officer() then s.email else null end,
      case when not s.anon or s.email = jwt_email() or is_officer() or is_test_admin() then s.first else 'Anonymous' end,
      case when not s.anon or s.email = jwt_email() or is_officer() or is_test_admin() then s.last else 'Member' end,
      case when not s.anon or s.email = jwt_email() or is_officer() or is_test_admin() then s.major else '' end,
      s.events, s.points, s.anon
    from lb_standings(since, null) s;
end $$;
grant execute on function public.leaderboard() to authenticated;
