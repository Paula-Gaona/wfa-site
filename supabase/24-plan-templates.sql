-- WFA update: editable standard planning checklists for each event type
-- (Officer tools > Event planning > Edit standard checklists). Admins edit them;
-- until then the site uses built-in defaults. Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.app_settings add column if not exists plan_templates jsonb not null default '{}'::jsonb;
