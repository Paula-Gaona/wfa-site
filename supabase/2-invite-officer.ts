// Supabase Edge Function: invite-officer
// Two jobs, picked by `action` in the request body:
//   "invite" (default): creates or updates an officer/admin account with a temporary
//      password, puts them on the access list, and emails their login details.
//   "send": sends an email from the officer email builder, with recipients in BCC.
//
// Needs these Edge Function secrets (Supabase -> Edge Functions -> Secrets):
//   RESEND_API_KEY   your Resend API key
//   MAIL_FROM        Wolverine Finance Association <noreply@wolverinefinanceassociation.org>
//   SITE_URL         https://wolverinefinanceassociation.org
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.
// Keep this file plain ASCII: pasting curly quotes into the editor can garble them.

import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const TIERS = ['president', 'vice_president', 'advisor', 'officer', 'honorary'];
const BRANCHES = ['', 'communications', 'operations', 'financial_applications'];

const escHtml = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));
// Wraps plain text in a simple branded HTML email (UVU green header).
function htmlEmail(text: string, button?: { label: string; url: string }) {
  const body = escHtml(text).replace(/\n/g, '<br>');
  const btn = button
    ? `<p style="margin:24px 0"><a href="${escHtml(button.url)}" style="background:#275D38;color:#ffffff;padding:12px 22px;border-radius:6px;text-decoration:none;font-weight:bold;display:inline-block">${escHtml(button.label)}</a></p>`
    : '';
  return `<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#0f1511">
  <div style="background:#275D38;color:#ffffff;padding:14px 20px;font-weight:bold;letter-spacing:.04em">WOLVERINE FINANCE ASSOCIATION</div>
  <div style="padding:20px;font-size:15px;line-height:1.55">${body}${btn}</div>
  <div style="padding:0 20px 20px;font-size:12px;color:#56655a">Wolverine Finance Association &middot; Utah Valley University</div>
</div>`;
}

async function resend(payload: Record<string, unknown>) {
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${Deno.env.get('RESEND_API_KEY')}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: Deno.env.get('MAIL_FROM'), ...payload }),
  });
  return { ok: r.ok, detail: r.ok ? '' : await r.text() };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
      auth: { persistSession: false },
    });

    const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
    const { data: { user } } = await admin.auth.getUser(token);
    if (!user?.email) return json({ error: 'Your session expired. Sign in again.' }, 401);
    const caller = user.email.toLowerCase();
    const { data: me } = await admin.from('access_list').select('role').eq('email', caller).maybeSingle();
    const log = (text: string) => admin.from('change_log').insert({ who: caller, text });
    const b = await req.json();
    const site = (Deno.env.get('SITE_URL') || '').replace(/\/+$/, '');

    // ---------- Email builder ----------
    if (b.action === 'send') {
      if (me?.role !== 'admin' && me?.role !== 'officer') return json({ error: 'Only officers can send club emails.' }, 403);
      const subject = String(b.subject || '').trim(), text = String(b.text || '').trim();
      const to = [...new Set((Array.isArray(b.to) ? b.to : []).map((e: unknown) => String(e).trim().toLowerCase()))]
        .filter((e) => EMAIL_RE.test(e as string)) as string[];
      if (!to.length) return json({ error: 'No valid recipients.' }, 400);
      if (to.length > 500) return json({ error: 'That is more than 500 recipients. Send to a smaller group.' }, 400);
      if (!subject || !text) return json({ error: 'Add a subject and a message.' }, 400);

      // Replies go to the sender's public contact email when they have one.
      const { data: prof } = await admin.from('officer_profiles').select('contact').eq('email', caller).maybeSingle();
      const replyTo = prof?.contact || caller;
      const fromAddr = (Deno.env.get('MAIL_FROM') || '').match(/<([^>]+)>/)?.[1] || Deno.env.get('MAIL_FROM');

      let sent = 0, failed = 0, lastError = '';
      for (let i = 0; i < to.length; i += 45) {
        const chunk = to.slice(i, i + 45);
        const r = await resend({ to: [fromAddr], bcc: chunk, reply_to: replyTo, subject, text, html: htmlEmail(text) });
        if (r.ok) sent += chunk.length; else { failed += chunk.length; lastError = r.detail; }
        if (i + 45 < to.length) await new Promise((res) => setTimeout(res, 600));   // stay under Resend's rate limit
      }
      await log(`Emailed "${subject}" to ${sent} ${sent === 1 ? 'person' : 'people'}${failed ? ` (${failed} failed)` : ''}`);
      if (!sent) return json({ error: 'The email service refused the message: ' + lastError }, 502);
      return json({ ok: true, sent, failed });
    }

    // ---------- Officer invite ----------
    if (me?.role !== 'admin') return json({ error: 'Only admins can add officers.' }, 403);
    const email = String(b.email || '').trim().toLowerCase();
    const first = String(b.first || '').trim(), last = String(b.last || '').trim();
    const role = b.role === 'admin' ? 'admin' : 'officer';
    const tier = TIERS.includes(b.tier) ? b.tier : 'officer';
    const branch = BRANCHES.includes(b.branch) ? b.branch : '';
    // How they sign in the first time:
    //   invite   - account created with a random password nobody sees; email explains how to set one with a reset code
    //   password - temporary password, emailed to them
    //   manual   - temporary password the admin shares in person (no email)
    //   skip     - no account; they sign up themselves
    const MODES = ['invite', 'password', 'manual', 'skip'];
    const mode = MODES.includes(b.mode) ? b.mode : (b.password ? 'password' : 'skip');
    let password = (mode === 'password' || mode === 'manual') ? String(b.password || '') : '';
    if (!EMAIL_RE.test(email)) return json({ error: 'Enter a valid login email.' }, 400);
    if (!first || !last) return json({ error: 'Enter their first and last name.' }, 400);
    if ((mode === 'password' || mode === 'manual') && password.length < 8) return json({ error: 'Temporary password needs at least 8 characters.' }, 400);

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
    } else if (mode !== 'skip') {
      const { error } = await admin.auth.admin.createUser({
        email, password: password || crypto.randomUUID() + 'Aa1!', email_confirm: true,
        user_metadata: { first, last, uvuid: '', majors: [], minor: '', must_change: !!password },
      });
      if (error) return json({ error: error.message }, 400);
      created = true;
    }

    const prof = await admin.from('officer_profiles').upsert({
      email, name: `${first} ${last}`, title: String(b.title || ''), tier, branch, bio: String(b.bio || ''),
      contact: String(b.contact || ''), hours: String(b.hours || ''), linkedin: String(b.linkedin || ''),
    });
    if (prof.error) return json({ error: prof.error.message }, 400);

    await log(`Gave ${email} ${role} access`);
    if (created) await log(`Created an account for ${first} ${last}`);
    else if (password) await log(`Set a temporary password for ${email}`);

    let emailed = false, warning = '';
    const sendEmail = mode === 'invite' || (mode === 'password' && b.send !== false);
    if (sendEmail) {
      const title = String(b.title || '') || (role === 'admin' ? 'an admin' : 'an officer');
      // Replies go to the admin's public contact email, which mail filters trust more than a no-reply address.
      const { data: prof2 } = await admin.from('officer_profiles').select('contact').eq('email', caller).maybeSingle();
      const replyTo = prof2?.contact || caller;
      let intro: string, link: string, label: string;
      if (mode === 'invite') {
        link = `${site}/#reset`; label = 'Set up your account';
        intro = `Hi ${first},\n\nYou have been added as ${title} for the Wolverine Finance Association.\n\n` +
          `To set up your account:\n1. Open the club website and choose "Forgot your password?" on the sign-in page.\n` +
          `2. Enter this email address: ${email}\n3. We will email you a 6-digit code. Enter it and choose your password.\n\n` +
          `After that, sign in with your email and the password you chose.`;
      } else {
        link = `${site}/#signin`; label = 'Sign in';
        intro = `Hi ${first},\n\nYou have been added as ${title} for the Wolverine Finance Association.\n\n` +
          `Login email: ${email}\nTemporary password: ${password}\n\n` +
          `The first time you sign in, you will choose your own password.`;
      }
      const r = await resend({
        to: [email], reply_to: replyTo, subject: `You've been added to the Wolverine Finance Association officer team`,
        text: `${intro}\n\n${label}: ${link}`,
        html: htmlEmail(intro, { label, url: link }),
      });
      if (r.ok) { emailed = true; await log(mode === 'invite' ? `Emailed setup instructions to ${email}` : `Emailed login details to ${email}`); }
      else warning = 'Saved, but the email did not send: ' + r.detail;
    }
    return json({ ok: true, created, emailed, warning });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 400);
  }
});
