-- WFA update: the Leaderboard page shows this season's prize (admins edit it there) and the active bonus point rules.
-- Run once in Supabase -> SQL Editor, after 56-point-rules.sql. Safe to run again.

-- The prize announcement shown at the top of the Leaderboard page.
alter table public.settings add column if not exists lb_prize text not null default
  'Prize for first place at the end of the semester! Ties for first are entered into a raffle.';

-- Everyone can see the bonus point rules (they're advertised on the Leaderboard and home pages). Only admins change them.
drop policy if exists "anyone reads point rules" on public.point_rules;
create policy "anyone reads point rules" on public.point_rules for select using (true);
grant select on public.point_rules to anon;
