// Supabase Edge Function: email-events
// Resend (the email service) calls this whenever a club email is delivered, opened, clicked, or bounces, and it saves
// the report in email_events (91-email-stats.sql). The email builder's "Recently sent" list shows the totals.
//
// Set up once:
//   1. Supabase -> Edge Functions -> Deploy a new function -> name it email-events -> paste this file -> Deploy.
//      Turn "Verify JWT" OFF for it (Resend calls it without signing in; the signature check below protects it).
//   2. Resend -> Webhooks -> Add endpoint:
//        URL: https://razxymbbfsnnnguyaalp.supabase.co/functions/v1/email-events
//        Events: email.delivered, email.opened, email.clicked, email.bounced, email.complained
//   3. Copy the endpoint's signing secret (starts with whsec_) into Supabase -> Edge Functions -> Secrets as
//      RESEND_WEBHOOK_SECRET.
// Keep this file plain ASCII: pasting curly quotes into the editor can garble them.

import { createClient } from 'npm:@supabase/supabase-js@2';

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

// Resend signs each call (Svix format): HMAC-SHA256 of "id.timestamp.body" with the secret after "whsec_".
async function verified(req: Request, body: string) {
  const secret = Deno.env.get('RESEND_WEBHOOK_SECRET') || '';
  const id = req.headers.get('svix-id') || '', ts = req.headers.get('svix-timestamp') || '', sigs = req.headers.get('svix-signature') || '';
  if (!secret || !id || !ts || !sigs) return false;
  if (Math.abs(Date.now() / 1000 - Number(ts)) > 600) return false;   // older than 10 minutes: refuse (replays)
  const raw = Uint8Array.from(atob(secret.replace(/^whsec_/, '')), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('raw', raw, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${id}.${ts}.${body}`)));
  const expected = btoa(String.fromCharCode(...mac));
  return sigs.split(' ').some((s) => s.split(',')[1] === expected);
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);
  const body = await req.text();
  if (!(await verified(req, body))) return json({ error: 'Bad signature' }, 401);
  try {
    const ev = JSON.parse(body);
    const type = String(ev.type || '').replace(/^email\./, '');
    const d = ev.data || {};
    if (!d.email_id || !type) return json({ ok: true, skipped: true });
    // Tags arrive as {name: value} or as [{name, value}].
    const tags = Array.isArray(d.tags) ? Object.fromEntries(d.tags.map((t: { name: string; value: string }) => [t.name, t.value])) : (d.tags || {});
    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const row = {
      at: ev.created_at || new Date().toISOString(), type, email_id: String(d.email_id),
      to_email: String((Array.isArray(d.to) ? d.to[0] : d.to) || '').toLowerCase().slice(0, 300),
      campaign: String(tags.campaign || '').slice(0, 100), link: String((d.click && d.click.link) || '').slice(0, 1000),
    };
    const r = await db.from('email_events').upsert(row, { onConflict: 'email_id,type,link', ignoreDuplicates: true });
    if (r.error) return json({ error: r.error.message }, 500);
    return json({ ok: true });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 400);
  }
});
