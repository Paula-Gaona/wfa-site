// Supabase Edge Function: auto-emails
// Sends the automatic club emails that admins turn on in Admin -> Automatic emails:
//   * event reminders (1 week / 1 day / 2 hours before an event) to people who RSVP'd (or confirmed case competition
//     teammates), or to all members
//   * a survey email 30 minutes after an event ends, to people who checked in and haven't answered the survey
// Supabase runs it every 10 minutes (see 39-automatic-emails.sql). Each event/email is recorded in auto_email_log
// before sending, so it never goes out twice, and calling it extra times only sends what is already due.
// Skips members who turned off club emails, test accounts, test events, drafts, and officer meetings.
//
// Deploy: Supabase -> Edge Functions -> Deploy a new function -> name it auto-emails -> paste this file -> Deploy.
// Then, in the function's settings, turn OFF "Verify JWT" (the scheduler calls it without signing in).
// It uses the same secrets as invite-officer (RESEND_API_KEY, MAIL_FROM, SITE_URL); nothing new to add.
// Keep this file plain ASCII: pasting curly quotes into the editor can garble them.

import { createClient } from 'npm:@supabase/supabase-js@2';

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const escHtml = (s: string) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));
const HOUR = 36e5, DAY = 864e5, STALE = 6 * HOUR;   // never send something more than 6 hours late
const OFFSETS: Record<string, number> = { '7d': 7 * DAY, '1d': DAY, '2h': 2 * HOUR };
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
const fromAddress = () => ((Deno.env.get('MAIL_FROM') || '').match(/<([^>]+)>/)?.[1] || Deno.env.get('MAIL_FROM') || '').trim();
async function resend(payload: Record<string, unknown>) {
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${Deno.env.get('RESEND_API_KEY')}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: Deno.env.get('MAIL_FROM'), ...payload }),
  });
  return { ok: r.ok, detail: r.ok ? '' : await r.text() };
}

Deno.serve(async () => {
  try {
    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const site = (Deno.env.get('SITE_URL') || '').replace(/\/+$/, '');
    const { data: st } = await db.from('settings').select('auto_email').eq('id', 1).single();
    const cfg = st?.auto_email;
    if (!cfg?.enabled) return json({ ok: true, sent: 0, note: 'Automatic emails are off.' });
    const now = Date.now();

    // Daily limit: emails used by automatic sends in the last 24 hours.
    const { data: recent } = await db.from('auto_email_log').select('emails').gte('sent_at', new Date(now - DAY).toISOString());
    let used = (recent || []).reduce((n: number, r: { emails: number }) => n + (r.emails || 0), 0);
    const cap = Math.max(0, Math.min(100, Number(cfg.daily_cap ?? 60)));

    const { data: events } = await db.from('events').select('id, title, cat, date, start_time, end_time, loc, descr, draft, test')
      .eq('draft', false).eq('test', false).neq('cat', 'officer_meeting')
      .gte('date', isoDay(now - 2 * DAY)).lte('date', isoDay(now + 8 * DAY));
    if (!events?.length) return json({ ok: true, sent: 0 });
    const ids = events.map((e) => e.id);
    const { data: done } = await db.from('auto_email_log').select('event_id, kind').in('event_id', ids);
    const already = new Set((done || []).map((r) => r.event_id + '|' + r.kind));

    // Who can be emailed: members who allow club emails, minus test accounts.
    const { data: members } = await db.from('members').select('email, email_opt_in');
    const { data: tests } = await db.from('test_accounts').select('email');
    const testSet = new Set((tests || []).map((t) => t.email));
    const okEmail = new Set((members || []).filter((m) => m.email_opt_in !== false && !testSet.has(m.email)).map((m) => m.email));
    const allMembers = [...okEmail];

    // Work out everything that's due.
    type Job = { ev: typeof events[number]; kind: string; to: string[]; subject: string; html: string; text: string };
    const jobs: Job[] = [];
    for (const ev of events) {
      const start = mtMs(ev.date, ev.start_time), end = mtMs(ev.date, ev.end_time);
      const link = `${site}/#event/${ev.id}`, when = `${fmtDay(start)}, ${fmtTime(start)} to ${fmtTime(end)}`;
      const footer = `You're getting this because you're a Wolverine Finance Association member. To stop club emails, turn them off in My account: <a href="${site}/#account" style="color:#1f4d2e">${site}/#account</a>`;
      const details = `<p style="margin:0 0 4px"><strong>${escHtml(ev.title)}</strong></p><p style="margin:0 0 4px">${escHtml(when)}</p>` +
        (ev.loc ? `<p style="margin:0 0 12px">${escHtml(ev.loc)}</p>` : '') +
        (ev.descr ? `<div style="margin:0 0 6px 18px;color:#3d4a40;white-space:pre-wrap">${escHtml(ev.descr)}</div>` : '');

      for (const r of (cfg.reminders || [])) {
        const offset = OFFSETS[r.key], kind = 'remind_' + r.key;
        if (!r.on || !offset || already.has(ev.id + '|' + kind)) continue;
        const sendAt = start - offset;
        if (now < sendAt || now >= start || now - sendAt > STALE) continue;
        let to: string[];
        if (r.to === 'all') to = allMembers;
        else if (ev.cat === 'case_competition') {
          const { data: tm } = await db.from('case_team_members').select('email, confirmed, case_teams!inner(status)').eq('event_id', ev.id).eq('confirmed', true).eq('case_teams.status', 'in');
          to = (tm || []).map((x) => x.email);
        } else {
          const { data: rs } = await db.from('rsvps').select('email').eq('event_id', ev.id);
          to = (rs || []).map((x) => x.email);
        }
        to = [...new Set(to)].filter((e) => okEmail.has(e));
        const phrase = r.key === '7d' ? `is coming up next week, on ${fmtDay(start)}` : r.key === '1d' ? `is tomorrow at ${fmtTime(start)}` : `starts today at ${fmtTime(start)}`;
        const subject = r.key === '7d' ? `Coming up: ${ev.title} on ${fmtDay(start)}` : r.key === '1d' ? `Tomorrow: ${ev.title}` : `Today at ${fmtTime(start)}: ${ev.title}`;
        const intro = r.to === 'all' ? `Hi everyone,` : `Hi! You're signed up for this, so here's a reminder.`;
        jobs.push({ ev, kind, to, subject,
          html: htmlEmail(`<p style="margin:0 0 12px">${escHtml(intro)}</p><p style="margin:0 0 16px">${escHtml(ev.title)} ${escHtml(phrase)}.</p>${details}`, { label: r.to === 'all' ? 'View the event and RSVP' : 'View the event', url: link }, footer),
          text: `${intro}\n\n${ev.title} ${phrase}.\n\n${when}\n${ev.loc || ''}\n\n${ev.descr || ''}\n\nView the event: ${link}` });
      }

      if (cfg.survey && !already.has(ev.id + '|survey')) {
        const sendAt = end + 30 * 60000;
        if (now >= sendAt && now - sendAt <= STALE) {
          const { data: att } = await db.from('attendance').select('email').eq('event_id', ev.id);
          const { data: sv } = await db.from('event_surveys').select('email').eq('event_id', ev.id);
          const answered = new Set((sv || []).map((x) => x.email));
          const to = [...new Set((att || []).map((x) => x.email))].filter((e) => okEmail.has(e) && !answered.has(e));
          const subject = `How was ${ev.title}?`;
          jobs.push({ ev, kind: 'survey', to, subject,
            html: htmlEmail(`<p style="margin:0 0 12px">Hi!</p><p style="margin:0 0 12px">Thanks for coming to <strong>${escHtml(ev.title)}</strong>. We'd love to hear what you thought. The survey is one star rating and an optional comment, it earns you 2 leaderboard points, and you can answer anonymously.</p><p style="margin:0 0 12px">It's open for 7 days.</p>`, { label: 'Take the 1-minute survey', url: `${site}/#account` }, footer),
            text: `Hi!\n\nThanks for coming to ${ev.title}. We'd love to hear what you thought. The survey is one star rating and an optional comment, it earns you 2 leaderboard points, and you can answer anonymously. It's open for 7 days.\n\nTake the survey: ${site}/#account` });
        }
      }
    }

    // Send. Claim each job in the log first (the unique key stops a second run from sending it again).
    const fromAddr = fromAddress(), results: string[] = [];
    for (const j of jobs) {
      const emails = Math.ceil(j.to.length / 45);
      const claim = await db.from('auto_email_log').insert({ event_id: j.ev.id, kind: j.kind, recipients: j.to.length, emails: 0, status: 'sending' }).select('id').single();
      if (claim.error) continue;   // already claimed by another run
      const id = claim.data.id;
      if (!j.to.length) { await db.from('auto_email_log').update({ status: 'skipped', detail: 'Nobody to send to' }).eq('id', id); continue; }
      if (used + emails > cap) { await db.from('auto_email_log').update({ status: 'skipped', detail: `Daily limit of ${cap} automatic emails reached` }).eq('id', id); continue; }
      let ok = 0, fail = 0, last = '';
      for (let i = 0; i < j.to.length; i += 45) {
        const r = await resend({ to: [fromAddr], bcc: j.to.slice(i, i + 45), subject: j.subject, text: j.text, html: j.html });
        if (r.ok) ok++; else { fail++; last = r.detail; }
        await new Promise((res) => setTimeout(res, 600));   // stay under Resend's rate limit
      }
      used += ok + fail;
      await db.from('auto_email_log').update({ status: ok ? 'sent' : 'failed', emails: ok + fail, detail: fail ? `${fail} of ${ok + fail} emails failed: ${last}`.slice(0, 500) : '' }).eq('id', id);
      await db.from('change_log').insert({ who: 'automatic emails', text: `Sent "${j.subject}" to ${j.to.length} ${j.to.length === 1 ? 'person' : 'people'}${fail ? ' (some failed)' : ''}` });
      results.push(j.kind);
    }
    return json({ ok: true, sent: results.length });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
