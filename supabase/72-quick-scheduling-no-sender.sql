-- WFA update: quick scheduling also covers older requests that don't record who sent them (sent_by is empty), so an
-- admin can sign those off too. Run once in Supabase -> SQL Editor, after 71-quick-scheduling.sql. Safe to run again.

create or replace function public.rq_quick_for(r event_requests) returns boolean
language sql stable security definer set search_path = public as $$
  select rq_quick() and (coalesce(r.sent_by, '') = ''
    or exists (select 1 from access_list a where a.email = r.sent_by and a.role = 'admin'));
$$;
grant execute on function public.rq_quick_for(event_requests) to authenticated;
