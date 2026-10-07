-- WFA update: "Careers in finance" overview on the Resources page, editable by officers.
-- Paste into Supabase -> SQL Editor -> New query, then Run.
-- Figures are rough entry-level U.S. numbers (2025-26) and should be reviewed each year.

create table public.careers (
  id uuid primary key default gen_random_uuid(),
  category text not null check (category in ('high', 'corporate')),
  title text not null,
  summary text not null default '',
  pay text not null default '',
  hours text not null default '',
  path text not null default '',      -- how to get in
  sort int not null default 0
);
alter table public.careers enable row level security;
create policy "anyone reads careers" on public.careers for select using (true);
create policy "officers add careers" on public.careers for insert with check (is_officer());
create policy "officers edit careers" on public.careers for update using (is_officer());
create policy "officers delete careers" on public.careers for delete using (is_officer());

insert into public.careers (category, sort, title, summary, pay, hours, path) values
('high', 0, 'Investment banking',
 $q$Advise companies on mergers and acquisitions and on raising money through stock and debt. Analysts build financial models, pitch books, and deal documents.$q$,
 $q$Analyst: about $110k–$120k base, $160k–$200k with bonus$q$,
 $q$70–90 hours a week$q$,
 $q$The main door is a junior-summer analyst internship, and banks recruit for it very early: start networking freshman and sophomore year, because applications can open in the spring of sophomore year. Most full-time offers come from the internship. Learn accounting, valuation (DCF and comparables), and Excel modeling.$q$),
('high', 1, 'Sales & trading',
 $q$Buy and sell securities such as stocks, bonds, currencies, and commodities for clients or the bank, and pitch market ideas to investors.$q$,
 $q$About $110k base, $150k–$180k with bonus$q$,
 $q$55–65 hours a week, with early starts tied to market hours$q$,
 $q$Same early timeline as investment banking, through bank summer analyst programs that rotate across trading desks. Follow the markets daily and be ready to pitch a trade or a stock in an interview.$q$),
('high', 2, 'Equity research',
 $q$Cover a group of public companies, build earnings models, and publish buy, hold, or sell ratings for investors.$q$,
 $q$About $100k–$110k base, $130k–$170k with bonus$q$,
 $q$55–70 hours a week, heavier during earnings season$q$,
 $q$Bank summer analyst programs on the same timeline as investment banking. A strong written stock pitch helps, and many analysts work toward the CFA charter.$q$),
('high', 3, 'Private equity',
 $q$Buy companies, improve them, and sell them years later. Associates screen deals, build LBO models, and work with portfolio companies.$q$,
 $q$Associate: about $150k–$200k base, $200k–$350k+ with bonus at larger firms$q$,
 $q$60–80 hours a week$q$,
 $q$Usually entered after about two years as an investment banking analyst; recruiting at large firms often starts within the first year of banking. A few firms hire straight out of college. Master LBO modeling.$q$),
('high', 4, 'Hedge funds',
 $q$Manage pooled money with strategies like long/short equity, credit, or macro. Analysts research ideas and pitch positions to portfolio managers.$q$,
 $q$Varies widely: about $150k–$300k+ all-in for analysts$q$,
 $q$50–70 hours a week$q$,
 $q$Most analysts come from two years in investment banking or equity research. Quant funds hire graduates with strong math and programming skills. Keep a portfolio of your own stock pitches.$q$),
('high', 5, 'Venture capital',
 $q$Invest in early-stage startups: find promising companies, evaluate them, and support their founders.$q$,
 $q$About $90k–$150k, sometimes with a share of fund profits later$q$,
 $q$50–60 hours a week$q$,
 $q$No standard pipeline. Firms hire through networking, startup or operating experience, and a few analyst programs, usually off-cycle. Stay close to the startup scene, such as Silicon Slopes here in Utah.$q$),
('high', 6, 'Asset & wealth management',
 $q$Invest money for institutions like pensions and mutual funds (asset management), or advise individuals and families on investments and financial plans (wealth management).$q$,
 $q$Asset management analyst: about $85k–$110k base, $100k–$140k with bonus. Wealth management: about $55k–$80k plus bonus or commission.$q$,
 $q$45–55 hours a week$q$,
 $q$Asset managers run junior-summer internships, often recruiting in the fall of junior year. Wealth management hires more at graduation. The CFA charter helps in asset management; the CFP credential helps in financial planning.$q$),
('corporate', 0, 'FP&A (financial planning & analysis)',
 $q$Build budgets and forecasts, analyze results, and help company leaders make decisions.$q$,
 $q$About $65k–$85k$q$,
 $q$40–50 hours a week, longer at month and quarter end$q$,
 $q$Junior-summer internships and finance rotational programs, which many large companies run. Recruiting happens mostly in the fall of junior and senior year. Strong Excel and accounting skills matter most.$q$),
('corporate', 1, 'Treasury',
 $q$Manage the company's cash, bank relationships, debt, and financial risks like interest rates and currencies.$q$,
 $q$About $65k–$85k$q$,
 $q$40–50 hours a week$q$,
 $q$Often entered through finance rotational programs or from FP&A and accounting roles, on the same fall recruiting timeline as FP&A.$q$),
('corporate', 2, 'Corporate development',
 $q$Lead the company's own acquisitions, partnerships, and strategic investments.$q$,
 $q$About $120k–$180k$q$,
 $q$50–60 hours a week$q$,
 $q$Rarely an entry-level job. Most people join after two to three years in investment banking, consulting, or FP&A.$q$),
('corporate', 3, 'Investor relations',
 $q$Explain the company's results and strategy to shareholders and analysts, and prepare earnings materials.$q$,
 $q$About $90k–$130k$q$,
 $q$45–55 hours a week, heavier around earnings$q$,
 $q$Usually after a few years in equity research, FP&A, or corporate communications.$q$),
('corporate', 4, 'Controllership & accounting',
 $q$Close the books each month, prepare financial statements, and keep reporting accurate.$q$,
 $q$About $60k–$75k$q$,
 $q$45–55 hours a week, longer during close and busy season$q$,
 $q$Accounting internships, including at the Big 4 public accounting firms, recruit in the fall of junior year. The CPA license is the main credential.$q$);
