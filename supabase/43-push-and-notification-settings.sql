-- WFA update: push notifications and notification settings.
--  * Each member picks, per kind of notification, whether they want a pop-up/phone notification and/or an email:
--    messages, event reminders, check-in is open, survey requests, new announcements (members.notify).
--  * Devices that turn on notifications are saved in push_subscriptions; the "push" Edge Function sends to them
--    even when the site or app is closed (supabase/push.ts).
--  * New chat messages and new announcements are pushed right away (the triggers below call the push function).
--    Event reminders, check-in-is-open, and survey requests are pushed by the auto-emails function on its schedule.
-- Before running: deploy the push Edge Function (see push.ts) and add its keys (Admin -> Automatic emails -> Push).
-- Run once in Supabase -> SQL Editor, after 42. Safe to run again.

-- Each member's choices. A missing key means "on".
-- Keys: messages_push, messages_email, events_push, events_email, checkin_push, surveys_push, surveys_email, announcements_push
alter table public.members add column if not exists notify jsonb not null default '{}'::jsonb;

-- The site's public push key (safe to share; the private key stays in the push function's secrets).
alter table public.settings add column if not exists push_public_key text not null default '';

-- Devices that turned on notifications.
create table if not exists public.push_subscriptions (
  endpoint text primary key,
  email text not null default public.jwt_email(),
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;
drop policy if exists "own devices" on public.push_subscriptions;
create policy "own devices" on public.push_subscriptions for all using (email = jwt_email()) with check (email = jwt_email());
grant select, insert, update, delete on public.push_subscriptions to authenticated;
grant select, insert, update, delete on public.push_subscriptions to service_role;

-- Each message and announcement is pushed once.
alter table public.messages add column if not exists pushed_at timestamptz;
alter table public.announcements add column if not exists pushed_at timestamptz;

-- Call the push function when a chat message or an announcement is posted.
create or replace function public.push_new_item() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform net.http_post(
    url := 'https://razxymbbfsnnnguyaalp.supabase.co/functions/v1/push',
    headers := '{"Content-Type": "application/json", "apikey": "sb_publishable_G9Ct3sh1zfK2peRadj-nzg_SSLCr2Sn"}'::jsonb,
    body := json_build_object(case when tg_table_name = 'messages' then 'message_id' else 'announcement_id' end, new.id)::jsonb);
  return new;
exception when others then return new;   -- a push problem must never stop a message from being saved
end $$;
drop trigger if exists messages_push on public.messages;
create trigger messages_push after insert on public.messages for each row execute function public.push_new_item();
drop trigger if exists announcements_push on public.announcements;
create trigger announcements_push after insert on public.announcements for each row execute function public.push_new_item();
