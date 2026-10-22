// Supabase Edge Function: push
// Sends push notifications (pop-ups on computers and phones, even when the site or app is closed).
// Three ways it gets called:
//   { message_id }       - by the database when a chat message is posted: notifies the chat's other members
//   { announcement_id }  - by the database when an announcement is posted: notifies members
//   { to, title, body, url, tag } - by the auto-emails function (event reminders, check-in open, survey requests).
//                          Only accepted with the service role key, so nobody else can send arbitrary pop-ups.
// Messages and announcements are each pushed once (pushed_at), so calling it again does nothing.
// Respects each member's Notification settings (members.notify) and skips devices that have expired.
//
// Deploy: Supabase -> Edge Functions -> Deploy a new function -> name it push -> paste this file -> Deploy.
// Then in its Details/Settings turn OFF "Verify JWT" and Save changes.
// Secrets (Edge Functions -> Secrets): VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY, from Admin -> Automatic emails -> Push.
// Keep this file plain ASCII: pasting curly quotes into the editor can garble them.

import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  try {
    const pub = Deno.env.get('VAPID_PUBLIC_KEY'), priv = Deno.env.get('VAPID_PRIVATE_KEY');
    if (!pub || !priv) return json({ ok: false, note: 'Push keys are not set up yet.' });
    const site = (Deno.env.get('SITE_URL') || 'https://wolverinefinanceassociation.org').replace(/\/+$/, '');
    webpush.setVapidDetails(site, pub, priv);
    const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const db = createClient(Deno.env.get('SUPABASE_URL')!, service, { auth: { persistSession: false } });
    const b = await req.json().catch(() => ({}));

    // Member choices: a missing key means "on".
    const { data: members } = await db.from('members').select('email, first, notify');
    const pref = new Map((members || []).map((m) => [m.email, m.notify || {}]));
    const wants = (email: string, key: string) => (pref.get(email) || {})[key] !== false;
    const { data: tests } = await db.from('test_accounts').select('email');
    const testSet = new Set((tests || []).map((t) => t.email));

    let to: string[] = [], title = '', body = '', url = site + '/', tag = '';

    if (b.message_id) {
      // Claim the message so it's pushed only once.
      const { data: m } = await db.from('messages').update({ pushed_at: new Date().toISOString() })
        .eq('id', b.message_id).is('pushed_at', null).select('id, chat_id, email, body').maybeSingle();
      if (!m) return json({ ok: true, sent: 0, note: 'Already sent or not found.' });
      const { data: chat } = await db.from('chats').select('id, kind, title').eq('id', m.chat_id).single();
      const { data: people } = await db.rpc('chat_member_emails', { cid: m.chat_id });
      to = (people || []).map((p: { email: string }) => p.email).filter((e: string) => e !== m.email && wants(e, 'messages_push'));
      const sender = (members || []).find((x) => x.email === m.email);
      const name = sender && sender.first ? sender.first : 'New message';
      title = chat && chat.title ? `${name} - ${chat.title}` : name;
      body = String(m.body).slice(0, 160);
      url = `${site}/#messages/${m.chat_id}`; tag = 'msg-' + m.id;

    } else if (b.announcement_id) {
      const { data: a } = await db.from('announcements').update({ pushed_at: new Date().toISOString() })
        .eq('id', b.announcement_id).is('pushed_at', null).select('id, title, body, test').maybeSingle();
      if (!a) return json({ ok: true, sent: 0, note: 'Already sent or not found.' });
      to = (members || []).map((x) => x.email).filter((e) => testSet.has(e) === !!a.test && wants(e, 'announcements_push'));
      title = 'WFA announcement: ' + a.title; body = String(a.body || '').slice(0, 160);
      url = `${site}/#home`; tag = 'ann-' + a.id;

    } else if (Array.isArray(b.to)) {
      if ((req.headers.get('Authorization') || '') !== `Bearer ${service}`) return json({ error: 'Not allowed.' }, 403);
      to = b.to; title = String(b.title || ''); body = String(b.body || ''); url = String(b.url || site + '/'); tag = String(b.tag || '');
    } else return json({ ok: true, sent: 0 });

    if (!to.length) return json({ ok: true, sent: 0 });
    const { data: subs } = await db.from('push_subscriptions').select('endpoint, email, p256dh, auth').in('email', to);
    const payload = JSON.stringify({ title, body, url, tag });
    let sent = 0;
    await Promise.all((subs || []).map(async (s) => {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400 });
        sent++;
      } catch (err) {
        const code = (err as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) await db.from('push_subscriptions').delete().eq('endpoint', s.endpoint);   // device turned off or gone
      }
    }));
    return json({ ok: true, sent });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
