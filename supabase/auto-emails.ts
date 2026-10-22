// Supabase Edge Function: auto-emails
// Sends the automatic club emails (and phone/computer notifications) that admins turn on in Admin -> Automatic emails:
//   * event reminders 1 week before, 1 day before, and the day of (9 AM, 2 hours before, or 1 hour before), to
//     everyone or to people who RSVP'd; for case competitions, only accepted teams (unless an admin turns that off)
//     Guests who RSVP'd without an account and asked for reminders get that event's reminders by email.
//   * "check-in is open" notifications 15 minutes before an event, to people who RSVP'd (notification only)
//   * a survey request 30 minutes after an event ends, to people who checked in and haven't answered the survey
//   * a summary email when chat messages sit unread for over an hour (see 42-chats.sql; works even when the
//     event emails are off)
// Each member chooses email and/or notification per kind in Notification settings (members.notify). By default,
// someone who gets a kind as a notification on a device doesn't also get the email for it.
// Each person gets their own email that greets them by first name (sent 100 at a time with Resend's batch API).
// Notifications go through the push function (supabase/push.ts).
// Supabase runs this every 10 minutes (see 39-automatic-emails.sql). Each event/kind is recorded in auto_email_log
// before sending, so it never goes out twice, and calling it extra times only sends what is already due.
// Skips members who turned off club emails (for emails), test accounts, test events, drafts, and officer meetings.
//
// Deploy: Supabase -> Edge Functions -> auto-emails -> Code -> paste this file -> Deploy.
// "Verify JWT" must be OFF for this function (the scheduler calls it without signing in).
// It uses the same secrets as invite-officer (RESEND_API_KEY, MAIL_FROM, SITE_URL); nothing new to add.
// Keep this file plain ASCII: pasting curly quotes into the editor can garble them.

import { createClient } from 'npm:@supabase/supabase-js@2';

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const escHtml = (s: string) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));
const HOUR = 36e5, DAY = 864e5, STALE = 6 * HOUR;   // never send something more than 6 hours late
const TZ = 'America/Denver';

// ---------- Mountain Time ----------
const partsFmt = new Intl.DateTimeFormat('en-US', { timeZone: TZ, year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', hourCycle: 'h23' });
function mtParts(ms: number) {
  const o: Record<string, number> = {};
  for (const p of partsFmt.formatToParts(new Date(ms))) if (p.type !== 'literal') o[p.type] = +p.value;
  return o;
}
const mtOffset = (ms: number) => { const p = mtParts(ms); return (Date.UTC(p.year, p.month - 1, p.day, p.hour % 24, p.minute) - Math.floor(ms / 60000) * 60000) / 60000; };
// A Mountain Time date ("2026-11-03") and clock time ("18:00") as a real moment (handles daylight saving).
function mtMs(date: string, time: string) {
  const [y, m, d] = date.split('-').map(Number), [h, mi] = String(time || '00:00').split(':').map(Number);
  const utc = Date.UTC(y, m - 1, d, h, mi);
  let ms = utc - mtOffset(utc) * 60000; ms = utc - mtOffset(ms) * 60000; return ms;
}
const fmtDay = (ms: number) => new Intl.DateTimeFormat('en-US', { timeZone: TZ, weekday: 'long', month: 'long', day: 'numeric' }).format(new Date(ms));
const fmtTime = (ms: number) => new Intl.DateTimeFormat('en-US', { timeZone: TZ, hour: 'numeric', minute: '2-digit' }).format(new Date(ms));
const isoDay = (ms: number) => { const p = mtParts(ms); return `${p.year}-${String(p.month).padStart(2, '0')}-${String(p.day).padStart(2, '0')}`; };

// ---------- Email ----------
function htmlEmail(bodyHtml: string, button: { label: string; url: string }, footer: string) {
  return `<div style="font-family:Arial,Helvetica,sans-serif;width:100%;color:#14231a">
  <div style="background:#123622;color:#ffffff;padding:14px 20px;font-weight:bold;letter-spacing:.08em;text-align:center;border-bottom:2px solid #b8923a">WOLVERINE FINANCE ASSOCIATION</div>
  <div style="padding:20px;font-size:15px;line-height:1.55">${bodyHtml}
    <p style="margin:24px 0"><a href="${escHtml(button.url)}" style="background:#1f4d2e;color:#ffffff;padding:12px 22px;border-radius:3px;text-decoration:none;font-weight:bold;display:inline-block">${escHtml(button.label)}</a></p></div>
  <div style="padding:0 20px 20px;font-size:12px;color:#5e6b60">${footer}</div>
</div>`;
}
// Sends up to 100 separate emails in one request.
async function resendBatch(emails: Record<string, unknown>[]) {
  const from = Deno.env.get('MAIL_FROM');
  const r = await fetch('https://api.resend.com/emails/batch', {
    method: 'POST',
    headers: { Authorization: `Bearer ${Deno.env.get('RESEND_API_KEY')}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(emails.map((e) => ({ from, ...e }))),
  });
  return { ok: r.ok, detail: r.ok ? '' : await r.text() };
}
// Phone/computer notifications, through the push function (only it holds the push keys).
async function sendPush(to: string[], title: string, body: string, url: string, tag: string) {
  if (!to.length) return 0;
  try {
    const r = await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/push`, {
      method: 'POST',
      // apikey: the site's public key (Supabase requires one on function calls). The service role key proves it's us.
      headers: { Authorization: `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}`, apikey: 'sb_publishable_G9Ct3sh1zfK2peRadj-nzg_SSLCr2Sn', 'Content-Type': 'application/json' },
      body: JSON.stringify({ to, title, body, url, tag }),
    });
    const j = await r.json().catch(() => ({}));
    return Number(j.sent || 0);
  } catch { return 0; }
}

Deno.serve(async () => {
  try {
    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const site = (Deno.env.get('SITE_URL') || '').replace(/\/+$/, '');
    const { data: st } = await db.from('settings').select('auto_email').eq('id', 1).single();
    const cfg = st?.auto_email;

    // Members, their choices, and who has a device signed up for notifications.
    const { data: members } = await db.from('members').select('email, email_opt_in, first, notify');
    const { data: tests } = await db.from('test_accounts').select('email');
    const { data: subs } = await db.from('push_subscriptions').select('email');
    const testSet = new Set((tests || []).map((t) => t.email));
    const hasDevice = new Set((subs || []).map((s) => s.email));
    const byEmail = new Map((members || []).map((m) => [m.email, m]));
    const choice = (email: string, key: string) => ((byEmail.get(email) || {}).notify || {})[key] !== false;   // missing = on
    const pushOn = cfg?.push !== false;
    // A notification for this kind will reach them on a device.
    const getsPush = (email: string, kind: string) => pushOn && hasDevice.has(email) && choice(email, kind + '_push');
    // An email for this kind: club emails on, this kind's email on, and not already covered by a notification
    // (unless they chose to get both).
    const getsEmail = (email: string, kind: string) => {
      const m = byEmail.get(email);
      if (!m || m.email_opt_in === false || testSet.has(email) || !choice(email, kind + '_email')) return false;
      return !(choice(email, 'skip_email_if_push') && getsPush(email, kind));
    };
    const firstName = new Map((members || []).map((m) => [m.email, String(m.first || '').trim()]));
    const hi = (email: string) => `Hi ${firstName.get(email) || 'there'},`;
    const real = (list: string[]) => [...new Set(list)].filter((e) => byEmail.has(e) && !testSet.has(e));

    // Chat alerts: one summary email to people with messages unread for over an hour (even when event emails are off).
    // chat_digest() only counts messages newer than each person's last alert, so nobody gets more than one per batch.
    let chatAlerts = 0;
    if (cfg?.chat_alerts !== false) {
      const { data: digest } = await db.rpc('chat_digest');
      const list = ((digest || []) as { email: string; first: string; unread: number; chats: string }[])
        .filter((d) => !(choice(d.email, 'skip_email_if_push') && getsPush(d.email, 'messages')));
      const chatFooter = `You're getting this because you have unread messages on the Wolverine Finance Association site. To stop these emails, change your Notification settings on the site: <a href="${site}/#account" style="color:#1f4d2e">${site}/#account</a>`;
      for (let i = 0; i < list.length; i += 100) {
        const chunk = list.slice(i, i + 100);
        const r = await resendBatch(chunk.map((d) => {
          const what = `You have ${d.unread} unread message${d.unread === 1 ? '' : 's'} in ${d.chats}.`;
          return { to: [d.email], subject: `You have ${d.unread} unread message${d.unread === 1 ? '' : 's'} on the WFA site`,
            html: htmlEmail(`<p style="margin:0 0 12px">${escHtml(`Hi ${d.first || 'there'},`)}</p><p style="margin:0 0 12px">${escHtml(what)}</p>`, { label: 'Open Messages', url: `${site}/#messages` }, chatFooter),
            text: `Hi ${d.first || 'there'},\n\n${what}\n\nOpen Messages: ${site}/#messages` };
        }));
        if (r.ok) {
          await db.from('chat_alerts').upsert(chunk.map((d) => ({ email: d.email, last_alert_at: new Date().toISOString() })));
          chatAlerts += chunk.length;
        }
        await new Promise((res) => setTimeout(res, 600));
      }
    }

    if (!cfg?.enabled) return json({ ok: true, sent: 0, chat_alerts: chatAlerts, note: 'Automatic emails are off.' });
    const now = Date.now();

    // Daily limit (a safety net): emails sent automatically in the last 24 hours, one per person.
    const { data: recent } = await db.from('auto_email_log').select('emails').gte('sent_at', new Date(now - DAY).toISOString());
    let used = (recent || []).reduce((n: number, r: { emails: number }) => n + (r.emails || 0), 0);
    const cap = Math.max(0, Math.min(5000, Number(cfg.daily_cap ?? 500)));

    const { data: events } = await db.from('events').select('id, title, cat, date, start_time, end_time, loc, descr, draft, test')
      .eq('draft', false).eq('test', false).neq('cat', 'officer_meeting')
      .gte('date', isoDay(now - 2 * DAY)).lte('date', isoDay(now + 8 * DAY));
    if (!events?.length) return json({ ok: true, sent: 0, chat_alerts: chatAlerts });
    const ids = events.map((e) => e.id);
    const { data: done } = await db.from('auto_email_log').select('event_id, kind').in('event_id', ids);
    const already = new Set((done || []).map((r) => r.event_id + '|' + r.kind));

    // People signed up for an event: RSVPs, or confirmed teammates on accepted teams for case competitions.
    async function signedUp(ev: { id: string; cat: string }) {
      if (ev.cat === 'case_competition') {
        const { data: tm } = await db.from('case_team_members').select('email, confirmed, case_teams!inner(status)').eq('event_id', ev.id).eq('confirmed', true).eq('case_teams.status', 'in');
        return (tm || []).map((x) => x.email);
      }
      const { data: rs } = await db.from('rsvps').select('email').eq('event_id', ev.id);
      return (rs || []).map((x) => x.email);
    }

    // Work out everything that's due. Each job has an email list and a notification list.
    type Job = { ev: typeof events[number]; kind: string; emailTo: string[]; pushTo: string[]; subject: string;
      html: (greeting: string) => string; text: (greeting: string) => string; push: { title: string; body: string; url: string } };
    const jobs: Job[] = [];
    for (const ev of events) {
      const start = mtMs(ev.date, ev.start_time), end = mtMs(ev.date, ev.end_time);
      const link = `${site}/#event/${ev.id}`, when = `${fmtDay(start)}, ${fmtTime(start)} to ${fmtTime(end)}`;
      const footer = `You're getting this because you're a Wolverine Finance Association member or asked for reminders about this event. Members can change which emails they get in Notification settings on the site, or turn club emails off in My account: <a href="${site}/#account" style="color:#1f4d2e">${site}/#account</a>`;
      const details = `<p style="margin:0 0 4px"><strong>${escHtml(ev.title)}</strong></p><p style="margin:0 0 4px">${escHtml(when)}</p>` +
        (ev.loc ? `<p style="margin:0 0 12px">${escHtml(ev.loc)}</p>` : '') +
        (ev.descr ? `<div style="margin:0 0 6px 18px;color:#3d4a40;white-space:pre-wrap">${escHtml(ev.descr)}</div>` : '');

      for (const r0 of (cfg.reminders || [])) {
        const r = r0.key === '2h' ? { ...r0, key: 'same', at: '2h' } : r0;   // older settings called the day-of reminder "2h"
        if (!r.on || !['7d', '1d', 'same'].includes(r.key)) continue;
        const kind = 'remind_' + r.key;
        if (already.has(ev.id + '|' + kind) || (r.key === 'same' && already.has(ev.id + '|remind_2h'))) continue;
        let sendAt: number;
        if (r.key === '7d') sendAt = start - 7 * DAY;
        else if (r.key === '1d') sendAt = start - DAY;
        else if (r.at === '9am') { const nine = mtMs(ev.date, '09:00'); sendAt = nine < start - HOUR ? nine : start - HOUR; }
        else sendAt = start - (r.at === '1h' ? 1 : 2) * HOUR;
        if (now < sendAt || now >= start || now - sendAt > STALE) continue;
        // Case competitions: only accepted teams (unless an admin chose otherwise). Everything else: everyone, or RSVPs.
        const teamsOnly = ev.cat === 'case_competition' && cfg.case_teams_only !== false;
        const base = real(teamsOnly || r.to === 'rsvp' ? await signedUp(ev) : (members || []).map((m) => m.email));
        const phrase = r.key === '7d' ? `is coming up next week, on ${fmtDay(start)}` : r.key === '1d' ? `is tomorrow at ${fmtTime(start)}` : `starts today at ${fmtTime(start)}`;
        const subject = r.key === '7d' ? `Coming up: ${ev.title} on ${fmtDay(start)}` : r.key === '1d' ? `Tomorrow: ${ev.title}` : `Today at ${fmtTime(start)}: ${ev.title}`;
        const toEveryone = !teamsOnly && r.to !== 'rsvp';
        const lead = teamsOnly ? `Just a reminder that ${ev.title}, which your team is competing in, ${phrase}.`
          : toEveryone ? `${ev.title} ${phrase}.` : `Just a reminder that ${ev.title}, which you signed up for, ${phrase}.`;
        const label = toEveryone ? 'View the event and RSVP' : 'View the event';
        // Guests who RSVP'd without an account and asked for reminders about this event.
        let guestTo: string[] = [];
        if (ev.cat !== 'case_competition') {
          const { data: gr } = await db.from('guest_rsvps').select('email, first').eq('event_id', ev.id).eq('reminders', true);
          (gr || []).forEach((g) => { if (!byEmail.has(g.email)) { guestTo.push(g.email); firstName.set(g.email, String(g.first || '').trim()); } });
          guestTo = [...new Set(guestTo)];
        }
        jobs.push({ ev, kind, subject, emailTo: [...base.filter((e) => getsEmail(e, 'events')), ...guestTo], pushTo: base.filter((e) => getsPush(e, 'events')),
          html: (g) => htmlEmail(`<p style="margin:0 0 12px">${escHtml(g)}</p><p style="margin:0 0 16px">${escHtml(lead)}</p>${details}`, { label, url: link }, footer),
          text: (g) => `${g}\n\n${lead}\n\n${when}\n${ev.loc || ''}\n\n${ev.descr || ''}\n\n${label}: ${link}`,
          push: { title: subject, body: `${fmtTime(start)}${ev.loc ? ' - ' + ev.loc : ''}`, url: link } });
      }

      // Check-in is open (15 minutes before the start): a notification only, to people signed up who haven't checked in.
      if (pushOn && !already.has(ev.id + '|checkin_open')) {
        const sendAt = start - 15 * 60000;
        if (now >= sendAt && now < end) {
          const { data: att } = await db.from('attendance').select('email').eq('event_id', ev.id);
          const here = new Set((att || []).map((x) => x.email));
          const base = real(await signedUp(ev)).filter((e) => !here.has(e));
          jobs.push({ ev, kind: 'checkin_open', subject: '', emailTo: [], pushTo: base.filter((e) => getsPush(e, 'checkin')),
            html: () => '', text: () => '', push: { title: `Check-in is open: ${ev.title}`, body: 'Tap to check in with the code on screen.', url: link } });
        }
      }

      if (cfg.survey && !already.has(ev.id + '|survey')) {
        const sendAt = end + 30 * 60000;
        if (now >= sendAt && now - sendAt <= STALE) {
          const { data: att } = await db.from('attendance').select('email').eq('event_id', ev.id);
          const { data: sv } = await db.from('event_surveys').select('email').eq('event_id', ev.id);
          const answered = new Set((sv || []).map((x) => x.email));
          const base = real((att || []).map((x) => x.email)).filter((e) => !answered.has(e));
          const body = `Thanks for coming to ${ev.title}! We'd love to hear what you thought. The survey is one star rating and an optional comment, it earns you 2 leaderboard points, and you can answer anonymously. It's open for 7 days.`;
          jobs.push({ ev, kind: 'survey', subject: `How was ${ev.title}?`, emailTo: base.filter((e) => getsEmail(e, 'surveys')), pushTo: base.filter((e) => getsPush(e, 'surveys')),
            html: (g) => htmlEmail(`<p style="margin:0 0 12px">${escHtml(g)}</p><p style="margin:0 0 12px">${escHtml(body)}</p><p style="margin:0 0 12px">Event: <a href="${escHtml(link)}" style="color:#1f4d2e">${escHtml(ev.title)}</a></p>`, { label: 'Take the 1-minute survey', url: `${site}/#account` }, footer),
            text: (g) => `${g}\n\n${body}\n\nEvent: ${link}\nTake the survey: ${site}/#account`,
            push: { title: `How was ${ev.title}?`, body: 'Take the 1-minute survey for 2 leaderboard points.', url: `${site}/#account` } });
        }
      }
    }

    // Send. Claim each job in the log first (the unique key stops a second run from sending it again).
    const results: string[] = [];
    for (const j of jobs) {
      const claim = await db.from('auto_email_log').insert({ event_id: j.ev.id, kind: j.kind, recipients: j.emailTo.length, emails: 0, status: 'sending' }).select('id').single();
      if (claim.error) continue;   // already claimed by another run
      const id = claim.data.id;
      const pushed = await sendPush(j.pushTo, j.push.title, j.push.body, j.push.url, `${j.kind}-${j.ev.id}`);
      if (!j.emailTo.length) {
        await db.from('auto_email_log').update({ status: pushed ? 'sent' : 'skipped', detail: pushed ? `Notified ${pushed} device${pushed === 1 ? '' : 's'}; no emails needed` : 'Nobody to send to' }).eq('id', id);
        continue;
      }
      if (used + j.emailTo.length > cap) { await db.from('auto_email_log').update({ status: 'skipped', detail: `Daily limit of ${cap} automatic emails reached` }).eq('id', id); continue; }
      let ok = 0, fail = 0, last = '';
      for (let i = 0; i < j.emailTo.length; i += 100) {
        const chunk = j.emailTo.slice(i, i + 100);
        const r = await resendBatch(chunk.map((email) => ({ to: [email], subject: j.subject, html: j.html(hi(email)), text: j.text(hi(email)) })));
        if (r.ok) ok += chunk.length; else { fail += chunk.length; last = r.detail; }
        await new Promise((res) => setTimeout(res, 600));   // stay under Resend's rate limit
      }
      used += ok + fail;
      const note = [pushed ? `also notified ${pushed} device${pushed === 1 ? '' : 's'}` : '', fail ? `${fail} of ${ok + fail} people didn't get it: ${last}` : ''].filter(Boolean).join('; ');
      await db.from('auto_email_log').update({ status: ok ? 'sent' : 'failed', emails: ok + fail, detail: note.slice(0, 500) }).eq('id', id);
      await db.from('change_log').insert({ who: 'automatic emails', text: `Sent "${j.subject}" to ${j.emailTo.length} ${j.emailTo.length === 1 ? 'person' : 'people'}${fail ? ' (some failed)' : ''}` });
      results.push(j.kind);
    }
    return json({ ok: true, sent: results.length, chat_alerts: chatAlerts });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
