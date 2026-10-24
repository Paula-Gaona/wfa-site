-- New questions and partner inquiries notify officers (the auto-emails function sends them; see auto-emails.ts).
-- notified_at records that officers were told, so each one is sent once.

alter table public.questions add column if not exists notified_at timestamptz;

-- Everything already in the inbox counts as notified, so turning this on doesn't send a burst of old ones.
update public.questions set notified_at = now() where notified_at is null;
