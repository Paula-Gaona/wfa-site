// Supabase Edge Function: invite-officer
// Creates (or updates) an officer/admin account with a temporary password,
// puts them on the access list, and emails their login details through Resend.
//
// Needs these Edge Function secrets (Supabase → Edge Functions → Secrets):
//   RESEND_API_KEY   your Resend API key
//   MAIL_FROM        e.g.  Wolverine Finance Association <noreply@yourdomain.com>
//   SITE_URL         e.g.  https://yourdomain.com
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
      auth: { persistSession: false },
    });

    // Only admins may call this.
    const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
    const { data: { user } } = await admin.auth.getUser(token);
    if (!user?.email) return json({ error: 'Your session expired. Sign in again.' }, 401);
    const caller = user.email.toLowerCase();
    const { data: me } = await admin.from('access_list').select('role').eq('email', caller).maybeSingle();
    if (me?.role !== 'admin') return json({ error: 'Only admins can add officers.' }, 403);

    const b = await req.json();
    const email = String(b.email || '').trim().toLowerCase();
    const first = String(b.first || '').trim(), last = String(b.last || '').trim();
    const role = b.role === 'admin' ? 'admin' : 'officer';
    const password = String(b.password || '');
    if (!EMAIL_RE.test(email)) return json({ error: 'Enter a valid login email.' }, 400);
    if (!first || !last) return json({ error: 'Enter their first and last name.' }, 400);
    if (password && password.length < 8) return json({ error: 'Temporary password needs at least 8 characters.' }, 400);

    // Access list first, so a last-admin problem stops everything before accounts change.
    const acc = await admin.from('access_list').upsert({ email, role });
    if (acc.error) return json({ error: acc.error.message }, 400);

    const { data: existing } = await admin.from('members').select('id').eq('email', email).maybeSingle();
    let created = false;
    if (existing) {
      await admin.from('members').update({ first, last }).eq('id', existing.id);
      if (password) {
        const { error } = await admin.auth.admin.updateUserById(existing.id, { password, user_metadata: { must_change: true } });
        if (error) return json({ error: error.message }, 400);
      }
    } else if (password) {
      const { error } = await admin.auth.admin.createUser({
        email, password, email_confirm: true,
        user_metadata: { first, last, uvuid: '', major: '', must_change: true },
      });
      if (error) return json({ error: error.message }, 400);
      created = true;
    }

    const prof = await admin.from('officer_profiles').upsert({
      email, name: `${first} ${last}`, title: String(b.title || ''), bio: String(b.bio || ''),
      contact: String(b.contact || ''), hours: String(b.hours || ''), linkedin: String(b.linkedin || ''),
    });
    if (prof.error) return json({ error: prof.error.message }, 400);

    const log = (text: string) => admin.from('change_log').insert({ who: caller, text });
    await log(`Gave ${email} ${role} access`);
    if (created) await log(`Created an account for ${first} ${last}`);
    else if (password) await log(`Set a temporary password for ${email}`);

    let emailed = false, warning = '';
    if (password && b.send) {
      const title = String(b.title || '') || (role === 'admin' ? 'an admin' : 'an officer');
      const site = Deno.env.get('SITE_URL') || 'the WFA website';
      const r = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${Deno.env.get('RESEND_API_KEY')}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          from: Deno.env.get('MAIL_FROM'),
          to: [email],
          subject: `Your Wolverine Finance Association ${role} account`,
          text: `Hi ${first},\n\nYou’ve been added as ${title} for the Wolverine Finance Association.\n\n` +
            `Sign in at ${site}\nLogin email: ${email}\nTemporary password: ${password}\n\n` +
            `You’ll be asked to choose your own password the first time you sign in.\n\nWolverine Finance Association`,
        }),
      });
      if (r.ok) { emailed = true; await log(`Emailed login details to ${email}`); }
      else warning = 'Saved, but the email didn’t send: ' + (await r.text());
    }
    return json({ ok: true, created, emailed, warning });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 400);
  }
});
