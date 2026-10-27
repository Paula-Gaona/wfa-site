-- WFA update: "Asset & wealth management" becomes two careers, "Asset management" (institutions) and
-- "Wealth management" (individuals and families), on the Resources page and in career interests.
-- Everyone who picked the old one gets both. A tailored resume for the old one moves to Asset management,
-- and partner inquiries that listed it list both. Run once in Supabase -> SQL Editor. Safe to run again.

do $$
declare s int;
begin
  select sort into s from public.careers where title = 'Asset & wealth management';
  if s is null then return; end if;   -- already split

  update public.careers set sort = sort + 1 where category = 'high' and sort > s;
  insert into public.careers (category, sort, title, summary, pay, hours, path) values
  ('high', s, 'Asset management',
   $q$Invest money for institutions like pensions, endowments, and mutual funds. Analysts research investments and help portfolio managers decide what to buy and sell.$q$,
   $q$Analyst: about $85k–$110k base, $100k–$140k with bonus$q$,
   $q$45–55 hours a week$q$,
   $q$Junior-summer internships, often recruiting in the fall of junior year. The CFA charter helps. Following the markets and pitching stocks shows real interest.$q$),
  ('high', s + 1, 'Wealth management',
   $q$Advise individuals and families on investing, retirement, taxes, and financial plans, often building your own book of clients over time.$q$,
   $q$About $55k–$80k plus bonus or commission, growing with the clients you bring in$q$,
   $q$40–50 hours a week$q$,
   $q$Firms hire more at graduation than through internships, and many run training programs for new advisors. Passing the SIE exam early helps; the CFP credential helps later on.$q$);

  update public.members
    set interests = array_remove(interests, 'Asset & wealth management') || array['Asset management', 'Wealth management']
    where 'Asset & wealth management' = any(interests);
  update public.member_resumes set category = 'Asset management'
    where category = 'Asset & wealth management'
      and not exists (select 1 from public.member_resumes r where r.member_id = member_resumes.member_id and r.category = 'Asset management');
  update public.questions
    set functions = array_remove(functions, 'Asset & wealth management') || array['Asset management', 'Wealth management']
    where 'Asset & wealth management' = any(functions);
  delete from public.careers where title = 'Asset & wealth management';
end $$;
