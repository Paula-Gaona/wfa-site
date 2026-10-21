-- STEP 1 (preview only, changes nothing): everyone who would be removed.
select u.email, u.created_at::date as created, coalesce(a.role, 'member') as role
from auth.users u
left join public.access_list a on a.email = lower(u.email)
where lower(u.email) <> 'paula.gaona@uvu.edu'
union all
select a.email, null, a.role || ' (no account yet)'
from public.access_list a
where a.email <> 'paula.gaona@uvu.edu'
  and not exists (select 1 from auth.users u where lower(u.email) = a.email)
order by 1;
