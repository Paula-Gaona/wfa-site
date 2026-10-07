// Supabase Edge Function: invite-officer
// Two jobs, picked by `action` in the request body:
//   "invite" (default): creates or updates an officer/admin account, puts them on the
//      access list, and emails them. The setup email carries a one-time setup code, so
//      the officer never needs a second email from Supabase's own mailer.
//   "send": sends an email from the officer email builder, one copy per recipient.
//
// Needs these Edge Function secrets (Supabase -> Edge Functions -> Secrets):
//   RESEND_API_KEY   your Resend API key
//   MAIL_FROM        Wolverine Finance Association <noreply@wolverinefinanceassociation.org>
//   SITE_URL         https://wolverinefinanceassociation.org   (no quotes, no trailing slash)
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.
// Keep this file plain ASCII: pasting curly quotes into the editor can garble them.
// After pasting a new copy, check that the site's admin page stops warning about an older copy.

import { createClient } from 'npm:@supabase/supabase-js@2';

// The site compares this with FUNCTION_VERSION in site/index.html. Change both together.
const VERSION = '2026-10-07';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify({ ...body, version: VERSION }), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
// Secrets pasted into the dashboard sometimes pick up spaces, or one pair of quotes around the whole value.
const env = (k: string) => {
  const v = (Deno.env.get(k) || '').trim();
  const m = v.match(/^(["'])([\s\S]*)\1$/);
  return (m ? m[2] : v).trim();
};
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const TIERS = ['president', 'vice_president', 'advisor', 'officer', 'honorary'];
const BRANCHES = ['', 'communications', 'operations', 'financial_applications'];

const escHtml = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));
// Wraps plain text in a simple branded HTML email (UVU green header). Web addresses become links.
function htmlEmail(text: string, button?: { label: string; url: string }) {
  const body = text.split(/(https:\/\/[^\s<>"]*[^\s<>".,;:!?)])/g)
    .map((part, i) => i % 2 ? `<a href="${escHtml(part)}" style="color:#275D38">${escHtml(part)}</a>` : escHtml(part))
    .join('').replace(/\n/g, '<br>');
  const btn = button
    ? `<p style="margin:24px 0"><a href="${escHtml(button.url)}" style="background:#275D38;color:#ffffff;padding:12px 22px;border-radius:6px;text-decoration:none;font-weight:bold;display:inline-block">${escHtml(button.label)}</a></p>`
    : '';
  return `<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#0f1511">
  <div style="background:#275D38;color:#ffffff;padding:14px 20px;font-weight:bold;letter-spacing:.04em">WOLVERINE FINANCE ASSOCIATION</div>
  <div style="padding:20px;font-size:15px;line-height:1.55">${body}${btn}</div>
  <div style="padding:0 20px 20px;font-size:12px;color:#56655a">Wolverine Finance Association &middot; Utah Valley University</div>
</div>`;
}

// Posts to Resend. `payload` is one email, or an array of up to 100 for the batch endpoint.
async function resend(payload: Record<string, unknown> | Record<string, unknown>[]) {
  const from = env('MAIL_FROM');
  const batch = Array.isArray(payload);
  const r = await fetch(batch ? 'https://api.resend.com/emails/batch' : 'https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${env('RESEND_API_KEY')}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(batch ? payload.map((p) => ({ from, ...p })) : { from, ...payload }),
  });
  if (r.ok) return { ok: true, detail: '' };
  // Resend answers {"statusCode":403,"name":"validation_error","message":"..."}; keep the readable part.
  const raw = await r.text();
  let detail = raw;
  try { const j = JSON.parse(raw); detail = [j.name, j.message].filter(Boolean).join(': ') || raw; } catch (_) { /* not JSON */ }
  return { ok: false, detail: `${detail} (HTTP ${r.status})` };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
      auth: { persistSession: false },
    });

    const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
    const { data: { user }, error: authError } = await admin.auth.getUser(token);
    if (!user?.email) {
      // A 4xx is a bad or expired sign-in; anything else is a server problem the admin should see as such.
      const status = (authError as { status?: number } | null)?.status || 0;
      if (authError && !(status >= 400 && status < 500)) return json({ error: 'The server could not check your sign-in: ' + authError.message }, 500);
      return json({ error: 'Your session expired. Sign in again.' }, 401);
    }
    const caller = user.email.toLowerCase();
    const { data: me } = await admin.from('access_list').select('role').eq('email', caller).maybeSingle();
    const log = (text: string) => admin.from('change_log').insert({ who: caller, text });
    const b = await req.json();
    // Links in emails. Falls back to the page the admin is using if the secret is missing.
    const site = (env('SITE_URL') || req.headers.get('origin') || '').replace(/\/+$/, '');

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

      // One copy per recipient (Resend batch, up to 100 per call). Each person sees their own address
      // in To, which university filters trust more than a hidden BCC list, and nothing goes to the
      // noreply address (it has no mailbox, so copies sent there bounce).
      const html = htmlEmail(text);
      let sent = 0, failed = 0, lastError = '';
      const pause = () => new Promise((res) => setTimeout(res, 600));   // stay under Resend's rate limit
      for (let i = 0; i < to.length; i += 100) {
        const chunk = to.slice(i, i + 100);
        const r = await resend(chunk.map((addr) => ({ to: [addr], reply_to: replyTo, subject, text, html })));
        if (r.ok) sent += chunk.length;
        else if (/validation_error|HTTP 422/.test(r.detail) && chunk.length > 1) {
          // Resend rejects the whole batch if one address is bad, so send that batch one by one.
          for (const addr of chunk) {
            await pause();
            const one = await resend({ to: [addr], reply_to: replyTo, subject, text, html });
            if (one.ok) sent++; else { failed++; lastError = `${addr}: ${one.detail}`; }
          }
        } else { failed += chunk.length; lastError = r.detail; }
        if (i + 100 < to.length) await pause();
      }
      await log(`Emailed "${subject}" to ${sent} ${sent === 1 ? 'person' : 'people'}${failed ? ` (${failed} failed: ${lastError.slice(0, 160)})` : ''}`);
      if (!sent) return json({ error: 'The email service refused the message: ' + lastError }, 502);
      return json({ ok: true, sent, failed, reason: failed ? lastError : '' });
    }

    // ---------- Officer invite ----------
    if (me?.role !== 'admin') return json({ error: 'Only admins can add officers.' }, 403);
    const email = String(b.email || '').trim().toLowerCase();
    const first = String(b.first || '').trim(), last = String(b.last || '').trim();
    const role = b.role === 'admin' ? 'admin' : 'officer';
    const tier = TIERS.includes(b.tier) ? b.tier : 'officer';
    const branch = BRANCHES.includes(b.branch) ? b.branch : '';
    // How they sign in the first time:
    //   invite   - new account gets a random password nobody sees; the email carries a setup code they enter
    //              on the site's #code page to choose a password. Someone who has signed in before keeps their
    //              password and the email says they now have access (with a code in case they cannot sign in).
    //   password - temporary password, emailed to them
    //   manual   - temporary password the admin shares in person (no email)
    //   skip     - no account and no email; they sign up themselves
    const MODES = ['invite', 'password', 'manual', 'skip'];
    const mode = MODES.includes(b.mode) ? b.mode : (b.password ? 'password' : 'skip');
    let password = (mode === 'password' || mode === 'manual') ? String(b.password || '') : '';
    if (!EMAIL_RE.test(email)) return json({ error: 'Enter a valid login email.' }, 400);
    if (!first || !last) return json({ error: 'Enter their first and last name.' }, 400);
    if ((mode === 'password' || mode === 'manual') && password.length < 8) return json({ error: 'Temporary password needs at least 8 characters.' }, 400);
    const sendEmail = mode === 'invite' || (mode === 'password' && b.send !== false);
    // Check before changing anything: a bad SITE_URL would put a broken link in the email.
    if (sendEmail && !/^https:\/\/[^\/\s]+$/.test(site)) {
      return json({ error: 'Server setup problem: the SITE_URL secret must look like https://wolverinefinanceassociation.org (no quotes, no trailing slash). Nothing was saved.' }, 500);
    }

    const acc = await admin.from('access_list').upsert({ email, role });
    if (acc.error) return json({ error: acc.error.message }, 400);

    const { data: existing } = await admin.from('members').select('id').eq('email', email).maybeSingle();
    let created = false;
    if (existing) {
      await admin.from('members').update({ first, last }).eq('id', existing.id);
      if (password) {
        // email_confirm: a member who never clicked their sign-up link could not use the password otherwise.
        const { error } = await admin.auth.admin.updateUserById(existing.id, { password, email_confirm: true, user_metadata: { must_change: true } });
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
    if (sendEmail) {
      const title = String(b.title || '') || (role === 'admin' ? 'an admin' : 'an officer');
      // Replies go to the admin's public contact email, which mail filters trust more than a no-reply address.
      const { data: prof2 } = await admin.from('officer_profiles').select('contact').eq('email', caller).maybeSingle();
      const replyTo = prof2?.contact || caller;
      let intro: string, link: string, label: string;
      if (mode === 'invite') {
        // The setup code goes in this email, so the officer needs nothing from Supabase's own mailer.
        // A code (not a link) also survives university link scanners, which open links before people do.
        const gl = await admin.auth.admin.generateLink({ type: 'recovery', email });
        const code = gl.error ? '' : String(gl.data?.properties?.email_otp || '');
        if (gl.error) await log(`Could not make a setup code for ${email}: ${gl.error.message}`);
        // Someone who has never signed in (an earlier invite, or a sign-up link that never got clicked)
        // gets the setup email too, not the "sign in as usual" one.
        let fresh = created;
        if (existing) {
          const { data: au } = await admin.auth.admin.getUserById(existing.id);
          fresh = !au?.user?.last_sign_in_at || !au?.user?.email_confirmed_at;
        }
        // #code opens straight to code entry, so pressing Enter cannot request a new code and cancel this one.
        const codeSteps = `1. Open ${site}/#code\n2. Enter this email address (${email}), the code, and the password you want.\n\n` +
          `If the code has expired, choose "Email me a new code" on that page.`;
        const noCodeSteps = `1. Open ${site}/#reset and enter this email address: ${email}\n` +
          `2. Choose "Email me a code". We will email you a code. Enter it and choose your password.`;
        if (!fresh) {
          link = `${site}/#signin`; label = 'Sign in';
          intro = `Hi ${first},\n\nYou now have ${title} access for the Wolverine Finance Association. ` +
            `Sign in with your usual email and password and you will see the officer tools.\n\n` +
            (code ? `If you cannot sign in, use this setup code to choose a new password: ${code}\n` + codeSteps
              : `If you cannot sign in:\n` + noCodeSteps);
        } else {
          link = code ? `${site}/#code` : `${site}/#reset`; label = 'Set up your account';
          intro = `Hi ${first},\n\nYou have been added as ${title} for the Wolverine Finance Association.\n\n` +
            (code ? `Your setup code: ${code}\n\nTo set up your account:\n` + codeSteps : `To set up your account:\n` + noCodeSteps) +
            `\n\nAfter that, sign in with your email and the password you chose.`;
        }
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
      else { warning = 'Saved, but the email did not send: ' + r.detail; await log(`Email to ${email} did not send: ${r.detail.slice(0, 160)}`); }
    }
    return json({ ok: true, created, emailed, warning, mode });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 400);
  }
});
