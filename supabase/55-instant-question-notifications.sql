-- New questions and partner inquiries notify officers right away: saving one calls the auto-emails function
-- (which tells the presidents and the Communications branch; see 54-question-notifications.sql) instead of waiting
-- for the 10-minute job. The job still runs as a backup; notified_at stops anything from going out twice.

create or replace function public.notify_new_question() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform net.http_post(
    url := 'https://razxymbbfsnnnguyaalp.supabase.co/functions/v1/auto-emails',
    -- The site's public (publishable) key, the same one in site/index.html. Supabase requires it on function calls.
    headers := '{"Content-Type": "application/json", "apikey": "sb_publishable_G9Ct3sh1zfK2peRadj-nzg_SSLCr2Sn"}'::jsonb,
    body := '{}'::jsonb);
  return new;
end $$;

drop trigger if exists questions_notify_now on public.questions;
create trigger questions_notify_now after insert on public.questions
  for each row execute function public.notify_new_question();
