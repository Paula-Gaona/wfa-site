-- WFA update: the automatic-emails schedule sends the site's public key, which Supabase now requires on
-- Edge Function calls. Run once in Supabase -> SQL Editor, after 39. Safe to run again.
select cron.unschedule(jobid) from cron.job where jobname = 'wfa-auto-emails';
select cron.schedule('wfa-auto-emails', '*/10 * * * *', $job$
  select net.http_post(
    url := 'https://razxymbbfsnnnguyaalp.supabase.co/functions/v1/auto-emails',
    headers := '{"Content-Type": "application/json", "apikey": "sb_publishable_G9Ct3sh1zfK2peRadj-nzg_SSLCr2Sn"}'::jsonb,
    body := '{}'::jsonb);
$job$);
