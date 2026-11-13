-- WFA update: the newsletter's "Bonus points" section is personalized, listing only the bonus points each member
-- hasn't earned yet. Officers (who build newsletters) can see who has earned which automatic point rule; members
-- still only see their own points. Run once in Supabase -> SQL Editor. Safe to run again.

create or replace function public.rule_earners() returns table (rule_id uuid, email text)
language sql stable security definer set search_path = public as $$
  select pa.rule_id, pa.email from point_awards pa where pa.rule_id is not null and public.is_officer()
$$;
revoke execute on function public.rule_earners() from public, anon;
grant execute on function public.rule_earners() to authenticated;
