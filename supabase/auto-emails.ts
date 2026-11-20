// Supabase Edge Function: auto-emails
// Sends the automatic club emails (and phone/computer notifications) that admins turn on in Admin -> Automatic emails:
//   * event reminders 1 week before, 1 day before, and the day of (9 AM, 2 hours before, or 1 hour before), to
//     everyone or to people who RSVP'd; for case competitions, only accepted teams (unless an admin turns that off)
//     Guests who RSVP'd without an account and asked for reminders get that event's reminders by email.
//   * "check-in is open" notifications 15 minutes before an event, and again at the start, to people who RSVP'd
//     and haven't checked in (notification only)
//   * a survey request 30 minutes after an event ends, to people who checked in and haven't answered the survey
//   * event scheduling steps (branch review, confirming with UVU, finalizing, sign-off): whoever a request is waiting on,
//     and the officer who sent it
//   * new questions and partner inquiries: the presidents and the Communications branch (see 54-question-notifications.sql)
//   * waitlists: anyone who just got a seat off an event's waitlist (see 62-rsvp-waitlist.sql)
//   * the Job openings email every Monday at 9 AM: up to 12 new job listings per person, matched to their year, career
//     interests, and big-name/Utah choice; only listings never emailed before (see 98-job-openings-email.sql)
//   * a start-of-semester reminder to update your profile, in January, May, and August (see 67-profile-reminders.sql)
//   * survey reminders at the times an officer picked in the survey builder, to members who haven't answered, with the
//     points they can earn (see 74-survey-reminders.sql)
//   * (not an email) applies the automatic leaderboard point rules each run (see 56-point-rules.sql)
//   * emails officers scheduled in the email builder, once their time comes (see 89-email-drafts-and-scheduling.sql)
//   * a summary email when chat messages sit unread for over an hour (see 42-chats.sql; works even when the
//     event emails are off)
// Each member chooses email and/or notification per kind in Notification settings (members.notify). By default,
// someone who gets a kind as a notification on a device doesn't also get the email for it.
// Each person gets their own email that greets them by first name (sent 100 at a time with Resend's batch API).
// Notifications are sent from here directly with web-push (the same VAPID secrets the push function uses); anyone a
// notification doesn't reach gets the email instead.
// Supabase runs this every 10 minutes (see 39-automatic-emails.sql). Each event/kind is recorded in auto_email_log
// before sending, so it never goes out twice, and calling it extra times only sends what is already due.
// Skips members who turned off club emails (for emails), test accounts, test events, drafts, and officer meetings.
//
// Deploy: Supabase -> Edge Functions -> auto-emails -> Code -> paste this file -> Deploy.
// "Verify JWT" must be OFF for this function (the scheduler calls it without signing in).
// It uses the same secrets as invite-officer (RESEND_API_KEY, MAIL_FROM, SITE_URL); nothing new to add.
// Keep this file plain ASCII: pasting curly quotes into the editor can garble them.

import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

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
// A moment plus some hours, not counting Saturdays or Sundays (Mountain Time); the approval timers use this.
function businessAdd(start: number, hours: number) {
  let t = start, rest = hours * HOUR;
  for (let i = 0; i < 60 && rest > 0; i++) {
    const p = mtParts(t), day = Date.UTC(p.year, p.month - 1, p.day), dow = new Date(day).getUTCDay();
    const dayIso = (n: number) => new Date(day + n * DAY).toISOString().slice(0, 10);
    if (dow === 0 || dow === 6) { t = mtMs(dayIso(dow === 6 ? 2 : 1), '00:00'); continue; }
    const sat = mtMs(dayIso(6 - dow), '00:00');
    if (t + rest <= sat) return t + rest;
    rest -= sat - t; t = sat;
  }
  return t;
}
const isoDay = (ms: number) => { const p = mtParts(ms); return `${p.year}-${String(p.month).padStart(2, '0')}-${String(p.day).padStart(2, '0')}`; };

// What a survey reminder says for one person: the points for the questions they'd see, any bonus-point rule they can
// still make, and when the survey closes. Officers and test accounts aren't ranked, so they get no points (ranked = false).
type SurveyQ = { points?: number; years?: string[] };
function surveyReminderCopy(sv: { title: string; closes_at: string | null; questions: SurveyQ[] }, rules: { points: number; deadline: string }[], year: string, ranked: boolean, now: number) {
  const forYear = (q: SurveyQ, y: string) => !(q.years || []).length || (q.years || []).includes(y);
  const total = (y: string) => (sv.questions || []).filter((q) => forYear(q, y)).reduce((n, q) => n + (Number(q.points) || 0), 0);
  // No year on their profile: the most anyone can earn, the same as the survey page.
  const years = [...new Set((sv.questions || []).flatMap((q) => q.years || []))];
  const pts = !ranked ? 0 : year || !years.length ? total(year) : Math.max(...years.map(total));
  const closes = sv.closes_at ? Date.parse(sv.closes_at) : Infinity;
  const stamp = (ms: number) => `${fmtDay(ms)} at ${fmtTime(ms)}`;
  const plural = (n: number) => `${n} ${n === 1 ? 'point' : 'points'}`;
  const bonus = ranked ? rules.filter((r) => r.points > 0 && Date.parse(r.deadline) > now).sort((a, b) => Date.parse(a.deadline) - Date.parse(b.deadline)) : [];
  const body = `You haven't answered "${sv.title}" yet. It only takes a few minutes${pts ? `, and you can earn up to ${plural(pts)} on the leaderboard for answering` : ''}.`
    + bonus.map((r) => ` Answer by ${stamp(Math.min(Date.parse(r.deadline), closes))} for ${r.points} bonus ${r.points === 1 ? 'point' : 'points'}.`).join('')
    + (closes < Infinity ? ` It closes ${stamp(closes)}.` : '');
  const most = pts + bonus.reduce((n, r) => n + r.points, 0);
  return { body, most, subject: `Reminder: ${sv.title}${most ? ` (earn up to ${plural(most)})` : ''}` };
}

// ---------- Email ----------
// Dress codes (the same ones as the site, 94-event-dress-code.sql): name, summary, and what to wear.
const DRESS: Record<string, [string, string, [string, string][]]> = {
  casual: ['Casual', 'Everyday clothes are fine.', []],
  neat_casual: ['Neat casual', 'Casual but put-together: no hoodies, sweats, or graphic tees.', [
    ['Men', 'jeans without rips or chinos, a plain T-shirt, henley, crewneck, or quarter-zip, and clean sneakers or boots'],
    ['Women', 'jeans without rips, casual pants, or a skirt, a plain T-shirt, nice top, or sweater, and clean sneakers, flats, or boots']]],
  smart_casual: ['Smart casual', 'A collared shirt or a nice top, with dark jeans or chinos.', [
    ['Men', 'dark jeans or chinos, a polo or button-down (or a sweater over a collared shirt), and loafers, boots, or leather sneakers'],
    ['Women', 'dark jeans or nice pants (or a casual dress), a blouse, nice sweater, or dressy top, and flats, boots, or leather sneakers']]],
  business_casual: ['Business casual', 'Slacks or chinos with a collared shirt or blouse; no jeans or sneakers.', [
    ['Men', 'slacks or chinos with a belt, a button-down or polo tucked in, an optional sweater or blazer (no tie needed), and loafers or dress shoes'],
    ['Women', 'slacks or a knee-length skirt or dress, a blouse, sweater, or nice top, an optional blazer or cardigan, and flats, loafers, or low heels']]],
  business_professional: ['Business professional', "A suit, or a suit-level outfit; what you'd wear to an interview.", [
    ['Men', 'a navy, charcoal, gray, or black suit, a pressed dress shirt and tie, and dress shoes with a matching belt'],
    ['Women', 'a pantsuit or skirt suit, or a conservative dress or skirt with a blazer, and closed-toe flats or modest heels'],
    ['No suit yet', 'a blazer with dress pants or a skirt is close enough.']]],
  semi_formal: ['Semi-formal', 'Dressy evening wear: a suit, a cocktail dress, or dressy separates.', [
    ['Men', 'a suit, or a blazer with dress pants, a tie if you like, and dress shoes'],
    ['Women', 'a cocktail dress or dressy jumpsuit, or dressy separates, with heels or dressy flats']]],
  outdoor: ['Outdoor / active', 'Comfortable clothes and closed-toe shoes for walking.', [
    ['Tip', 'Check the weather, and bring layers, water, and sun protection if you will be outside.']]],
};
// Networking tips for the day-before reminder of bigger events.
const PREP: Record<string, string[]> = {
  guest_speaker: [
    'Look up the speaker and their firm on LinkedIn, and come with one or two questions.',
    'Arrive a few minutes early and sit near the front.',
    'Stay after to thank the speaker: a handshake, your name, and one thing you took away.',
    'Connect on LinkedIn within a day or two, with a short note mentioning something from the talk.',
  ],
  panel: [
    'Look up the panelists and their firms on LinkedIn, and come with one or two questions.',
    'Arrive a few minutes early and sit near the front.',
    'Stay after to thank the panelists: a handshake, your name, and one thing you took away.',
    'Connect on LinkedIn within a day or two, with a short note mentioning something from the panel.',
  ],
  career_fair: [
    'Bring printed copies of your resume (10 or more) in a padfolio if you have one (a folder works too), and a pen.',
    'Check which firms are coming on the event page, and pick the ones you most want to meet.',
    'Practice a 30-second intro: your name, year, major, and what kind of role you want.',
    'Ask about internships, timelines, and how they recruit at UVU, and get each recruiter\'s name.',
    'Follow up within 24 hours with a short thank-you email or LinkedIn note.',
  ],
  excursion: [
    'Read up on the firm you are visiting: what it does, and recent news.',
    'Have two or three questions ready about the roles, the culture, and how students get hired.',
    'Be on time to the meeting spot, and put your phone away during the visit.',
    'Introduce yourself to the people you meet, and send a thank-you note afterward.',
  ],
  case_competition: [
    'Get there early, and have your slides and files ready to go.',
    'Introduce your team to the judges before or after you present.',
    'Ask the judges for feedback after the round; it is the best networking you will get.',
    'Connect with the judges on LinkedIn afterward, mentioning your team and case.',
  ],
};

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
// Phone/computer notifications, sent straight to each signed-up device. Returns who it reached, so anyone it didn't
// reach can get an email instead. Devices that have expired or been turned off are removed.
let vapidReady: boolean | null = null;
function vapid() {
  if (vapidReady === null) {
    const pub = Deno.env.get('VAPID_PUBLIC_KEY'), priv = Deno.env.get('VAPID_PRIVATE_KEY');
    vapidReady = !!(pub && priv);
    if (vapidReady) webpush.setVapidDetails((Deno.env.get('SITE_URL') || 'https://wolverinefinanceassociation.org').replace(/\/+$/, ''), pub!, priv!);
  }
  return vapidReady;
}
// deno-lint-ignore no-explicit-any
async function sendPush(db: any, to: string[], title: string, body: string, url: string, tag: string) {
  const reached = new Set<string>();
  if (!to.length || !vapid()) return reached;
  const { data: subs } = await db.from('push_subscriptions').select('endpoint, email, p256dh, auth').in('email', to);
  const payload = JSON.stringify({ title, body, url, tag });
  await Promise.all((subs || []).map(async (s: { endpoint: string; email: string; p256dh: string; auth: string }) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400 });
      reached.add(s.email);
    } catch (err) {
      const code = (err as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await db.from('push_subscriptions').delete().eq('endpoint', s.endpoint);
    }
  }));
  return reached;
}

// Scheduled emails from the email builder (89-email-drafts-and-scheduling.sql): each one's emails were prepared when
// it was scheduled (one per person). Sends any that are due, 100 at a time, skipping anyone who has since turned off
// club emails. Claiming a draft ("scheduled" -> "sending") first means it can't go out twice, and an officer who
// cancels it before then stops it.
// deno-lint-ignore no-explicit-any
async function sendScheduled(db: any) {
  const { data: due } = await db.from('email_drafts').update({ status: 'sending' }).eq('status', 'scheduled')
    .lte('send_at', new Date().toISOString()).select('id, subject');
  let total = 0;
  for (const d of due || []) {
    const { data: rows } = await db.from('email_outbox').select('id, to_email, subject, text, html, check_opt_out').eq('draft_id', d.id).is('sent_at', null);
    const list = rows || [];
    const { data: off } = await db.from('members').select('email').eq('email_opt_in', false).in('email', list.map((r: { to_email: string }) => r.to_email));
    const offSet = new Set((off || []).map((m: { email: string }) => m.email));
    const go = list.filter((r: { to_email: string; check_opt_out: boolean }) => !(r.check_opt_out && offSet.has(r.to_email)));
    let ok = 0, fail = 0, last = '';
    for (let i = 0; i < go.length; i += 100) {
      const chunk = go.slice(i, i + 100);
      const r = await resendBatch(chunk.map((m: { to_email: string; subject: string; text: string; html: string }) => ({ to: [m.to_email], subject: m.subject, text: m.text, html: m.html, tags: [{ name: 'campaign', value: d.id }] })));
      const ids = chunk.map((m: { id: number }) => m.id);
      if (r.ok) { ok += chunk.length; await db.from('email_outbox').update({ sent_at: new Date().toISOString() }).in('id', ids); }
      else { fail += chunk.length; last = r.detail; await db.from('email_outbox').update({ error: r.detail.slice(0, 500) }).in('id', ids); }
      if (i + 100 < go.length) await new Promise((res) => setTimeout(res, 600));
    }
    const skipped = list.length - go.length;
    const detail = [skipped ? `${skipped} turned off club emails` : '', fail ? `${fail} failed: ${last}` : ''].filter(Boolean).join('; ').slice(0, 500);
    await db.from('email_drafts').update({ status: ok || !go.length ? 'sent' : 'failed', sent_at: new Date().toISOString(), sent_count: ok, detail }).eq('id', d.id);
    await db.from('change_log').insert({ who: 'scheduled email', text: `Sent the scheduled email "${d.subject}" to ${ok} ${ok === 1 ? 'person' : 'people'}${fail ? ` (${fail} failed)` : ''}` });
    total += ok;
  }
  return total;
}

Deno.serve(async () => {
  try {
    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const site = (Deno.env.get('SITE_URL') || '').replace(/\/+$/, '');
    const { data: st } = await db.from('settings').select('auto_email').eq('id', 1).single();
    const cfg = st?.auto_email;
    // Scheduled emails from the email builder go out first, whether or not the automatic emails are on.
    let scheduled = 0;
    try { scheduled = await sendScheduled(db); } catch (_) { /* not set up yet (89-email-drafts-and-scheduling.sql) */ }

    // Members, their choices, and who has a device signed up for notifications.
    const { data: members } = await db.from('members').select('email, email_opt_in, first, notify, year, interests, job_focus');
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

    // Event scheduling (see 52-event-scheduling.sql; works even when the event emails are off). Each step tells the
    // people it's waiting on: branch presidents, presidents, or schedulers (right away, then a reminder), and the
    // officer who sent it hears when it's sent back, submitted to UVU, or published.
    // As a notification on a device if they have one signed up, otherwise by email.
    let schedNotes = 0;
    const tell = async (to: string[], subject: string, body: string, label: string, url: string, tag: string) => {
      to = [...new Set(to)].filter((e) => e && !testSet.has(e));
      // A notification where they have a device signed up; an email for everyone it didn't reach.
      const reached = await sendPush(db, to.filter((e) => pushOn && hasDevice.has(e)), subject, body, url, tag);
      const viaEmail = to.filter((e) => !reached.has(e));
      let n = reached.size;
      if (viaEmail.length) {
        const footer = `You're getting this because you're an officer on the Wolverine Finance Association site.`;
        const r = await resendBatch(viaEmail.map((e) => ({ to: [e], subject,
          html: htmlEmail(`<p style="margin:0 0 12px">${escHtml(hi(e))}</p><p style="margin:0 0 12px;white-space:pre-wrap">${escHtml(body)}</p>`, { label, url }, footer),
          text: `${hi(e)}\n\n${body}\n\n${label}: ${url}` })));
        if (r.ok) n += viaEmail.length;
      }
      schedNotes += n;
      return n > 0 || !to.length;
    };
    await db.rpc('request_timeouts');   // presidents' reviews that waited 48 hours move on
    await db.rpc('apply_point_rules');  // automatic point rules: new qualifiers get points, no-shows lose them (56-point-rules.sql)
    const { data: reqs } = await db.from('event_requests').select('event_id, status, status_by, note, signoff_note, sent_by, sent_at, status_at, nudged_at, branch, votes, history').in('status', ['branch', 'review', 'sent', 'returned', 'submitted', 'approved', 'signoff', 'adminok', 'published']);
    if (reqs?.length) {
      const { data: evs } = await db.from('events').select('id, title, cat, date').in('id', reqs.map((r) => r.event_id));
      const titleOf = new Map((evs || []).map((e) => [e.id, e.title])), evOf = new Map((evs || []).map((e) => [e.id, e]));
      const BIG = ['case_competition', 'excursion', 'guest_speaker', 'panel', 'career_fair'];
      const { data: sch } = await db.from('event_schedulers').select('email');
      const schedulers = (sch || []).map((s) => s.email);
      const { data: offs } = await db.from('officer_profiles').select('email, tier, branch');
      const { data: acc } = await db.from('access_list').select('email');
      const isOfficer = new Set((acc || []).map((a) => a.email));
      const presidents = (offs || []).filter((o) => o.tier === 'president' && isOfficer.has(o.email));
      const vps = (offs || []).filter((o) => o.tier === 'vice_president' && isOfficer.has(o.email)).map((o) => o.email);
      const branchPres = (b: string | null) => { const p = (offs || []).filter((o) => b && o.branch === b && ['president', 'vice_president'].includes(o.tier) && isOfficer.has(o.email)); return (p.length ? p : presidents).map((o) => o.email); };
      const nowMs = Date.now(), ms = (t: string | null) => (t ? new Date(t).getTime() : 0);
      const who = (e: string) => firstName.get(e) || e || 'An officer';
      const deadline = (r: { status_at: string }) => { const d = businessAdd(ms(r.status_at), 48); return `${fmtDay(d)} at ${fmtTime(d)}`; };
      for (const r of reqs) {
        const t = titleOf.get(r.event_id) || 'an event';
        const link = `${site}/#officer/scheduling/${r.event_id}`, tag = `sched-${r.event_id}`;
        const fresh = ms(r.nudged_at) < ms(r.status_at);
        let to: string[] = [], subject = '', body = '', again = 0;   // again: remind after this long (0 = once)
        if (r.status === 'branch') {
          to = branchPres(r.branch); again = 2 * DAY;
          subject = fresh ? `Review an event: ${t}` : `Still waiting for your review: ${t}`;
          const lastNote = ((r.history || [])[(r.history || []).length - 1] || {}).note || '';
          body = /^Back to branch leadership/.test(lastNote)
            ? `The presidents sent "${t}" back to the branch leadership to fix. Their suggested changes are on the event; make them (or say why not), then approve it again.

${lastNote}`
            : `${who(r.sent_by || '')} made "${t}" and needs approval from their branch president or vice president before it moves on. Edit and approve it, or send it back with notes.`;
        } else if (r.status === 'review' || r.status === 'signoff') {
          const voted = r.votes || {}, ev = evOf.get(r.event_id) || {};
          const presSched = presidents.some((o) => o.email === r.status_by);
          const small = r.status === 'signoff' && !BIG.includes(ev.cat);
          const auto = r.status === 'review' || presSched;              // only these publish/move on by themselves
          const escalated = small && !presSched && nowMs >= businessAdd(ms(r.status_at), 36);
          to = presidents.map((o) => o.email).filter((e) => e !== r.status_by && !(e in voted));
          if (escalated) to = [...to, ...vps.filter((e) => !(e in voted))];
          again = DAY;
          const overdue = !auto && nowMs >= businessAdd(ms(r.status_at), 48);
          const vpsJustAdded0 = escalated && ms(r.nudged_at) < businessAdd(ms(r.status_at), 36);
          const what = r.status === 'review' ? 'every president\'s approval before it goes to UVU'
            : small ? `one approval from a president${escalated ? ' or vice president' : ''} before it is published` : 'every president\'s approval before it is published';
          subject = fresh ? `${r.status === 'review' ? 'Presidents\' review' : 'Sign-off'}: ${t}` : overdue ? `Overdue: ${t} is waiting for approval` : vpsJustAdded0 ? `Sign-off needed: ${t}` : `Reminder: ${t}`;
          body = `"${t}" needs ${what}. Approve it or request changes. `
            + (auto ? `If nobody objects, it moves on automatically on ${deadline(r)}.` : `It won't be published until someone approves it${ev.date ? ` (the event is ${fmtDay(mtMs(ev.date, '12:00'))})` : ''}.`);
          // One reminder a day, plus one right when the vice presidents are brought in.
          const vpsJustAdded = escalated && ms(r.nudged_at) < businessAdd(ms(r.status_at), 36);
          if (!fresh && !vpsJustAdded && nowMs - ms(r.nudged_at) < DAY) to = [];
          if (vpsJustAdded) again = 1;
        } else if (r.status === 'sent') {
          to = schedulers; again = 2 * DAY;
          const days = Math.floor((nowMs - ms(r.status_at)) / DAY);
          subject = fresh ? `Confirm with UVU: ${t}` : `Still waiting to be confirmed with UVU: ${t}`;
          body = fresh ? `"${t}" is ready to confirm with UVU. Mark it confirmed once UVU agrees, or send it back with notes.` : `"${t}" has been waiting ${days} days. Confirm it with UVU, or send it back with notes.`;
        } else if (r.status === 'approved') {
          to = schedulers; again = 2 * DAY;
          subject = r.signoff_note ? `Changes requested: ${t}` : `Finalize and send for sign-off: ${t}`;
          body = r.signoff_note ? `A president asked for changes to "${t}":\n${r.signoff_note}\n\nMake them, then send it to the presidents again.`
            : `UVU confirmed "${t}". Set the final date, times, location, and RSVP timing, then send it to the presidents for sign-off.`;
        } else if (r.status === 'adminok') {
          // Quick scheduling (71-quick-scheduling.sql): the admin who sent it signs off instead of the presidents.
          to = [r.sent_by || '']; again = DAY;
          subject = fresh ? `Sign off on your event: ${t}` : `Reminder: sign off on ${t}`;
          body = `A scheduler confirmed "${t}" with UVU and set the final details. Quick scheduling is on, so you sign off: publish it, or send it back to the scheduler with notes.`;
        } else if (r.status === 'returned') {
          to = [r.sent_by || '']; subject = `Changes needed: ${t}`;
          body = `"${t}" was sent back. What to fix:\n${r.note || '(no note)'}\n\nMake the changes, then send it again.`;
        } else if (r.status === 'published') {
          if (nowMs - ms(r.status_at) > 3 * DAY) continue;
          to = [r.sent_by || '']; subject = `Published: ${t}`;
          body = `"${t}" is approved and on the calendar. You can start promoting it.`;
        }
        // Passed by majority: every president hears about it too.
        const last = (r.history || [])[(r.history || []).length - 1] || {};
        if (fresh && /majority/i.test(last.note || '') && (r.status === 'sent' || r.status === 'published')) {
          to = [...to, ...presidents.map((o) => o.email)];
          body += `\n\n${last.note}`;
        }
        if (!to.length || !subject) continue;
        if (!fresh && !(again && nowMs - ms(r.nudged_at) >= again)) continue;
        if (await tell(to, subject, body, 'Open it', r.status === 'published' ? `${site}/#event/${r.event_id}` : link, tag))
          await db.from('event_requests').update({ nudged_at: new Date().toISOString() }).eq('event_id', r.event_id);
      }
    }

    // New questions (Contact page) and partner inquiries (Partner with us): tell the presidents and the Communications
    // branch once each (see 54-question-notifications.sql). Works even when the event emails are off.
    const { data: newQs } = await db.from('questions').select('id, kind, name, email, company, job_title, topic, ways, availability').eq('status', 'new').is('notified_at', null).limit(50);
    if (newQs?.length) {
      const { data: offs } = await db.from('officer_profiles').select('email, tier, branch');
      const { data: acc } = await db.from('access_list').select('email');
      const isOfficer = new Set((acc || []).map((a) => a.email));
      const to = (offs || []).filter((o) => isOfficer.has(o.email) && (o.tier === 'president' || o.branch === 'communications')).map((o) => o.email);
      const link = `${site}/#officer/questions`;
      // "When works best" from the Partner form: months, and half-hour weekday slots like "mon-540" (9:00 AM).
      const clock = (m: number) => { const h = Math.floor(m / 60), mm = m % 60; return `${h % 12 || 12}:${String(mm).padStart(2, '0')} ${h >= 12 ? 'PM' : 'AM'}`; };
      const whenText = (a: { months?: string[]; slots?: string[] } | null) => {
        if (!a) return '';
        const days = [['mon', 'Mon'], ['tue', 'Tue'], ['wed', 'Wed'], ['thu', 'Thu'], ['fri', 'Fri']].map(([k, l]) => {
          const mins = (a.slots || []).filter((x) => x.startsWith(k + '-')).map((x) => +x.split('-')[1]).sort((x, y) => x - y);
          const out: number[][] = [];
          mins.forEach((m) => { const r = out[out.length - 1]; if (r && r[1] === m) r[1] = m + 30; else out.push([m, m + 30]); });
          return out.length ? `${l} ${out.map(([x, y]) => clock(x) + '-' + clock(y)).join(', ')}` : '';
        }).filter(Boolean).join('; ');
        return [(a.months || []).length ? '\nMonths: ' + a.months!.join(', ') : '', days ? '\nTimes: ' + days : ''].join('');
      };
      for (const q of newQs) {
        const who = q.name || q.email || 'Someone';
        const partner = q.kind === 'partner';
        const subject = partner ? `New partner inquiry: ${q.company || who}` : `New question from ${who}`;
        const body = partner
          ? `${who}${q.job_title ? ', ' + q.job_title : ''}${q.company ? ' at ' + q.company : ''} reached out through Partner with us.${(q.ways || []).length ? '\nInterested in: ' + q.ways.join(', ') : ''}${whenText(q.availability)}\n\nReply from Officer tools -> Questions.`
          : `${who} asked a question${q.topic ? ' about ' + q.topic.toLowerCase() : ''} on the Contact page.\n\nReply from Officer tools -> Questions.`;
        if (await tell(to, subject, body, 'Open Questions', link, `question-${q.id}`))
          await db.from('questions').update({ notified_at: new Date().toISOString() }).eq('id', q.id);
      }
    }

    // Membership milestones (see 115-member-milestones.sql): tell every officer once each time the club passes another
    // 50 members. Claimed in member_milestones first so it only goes out once. Works even when the event emails are off.
    try {
      const total = real((members || []).map((m) => m.email)).length, mark = Math.floor(total / 50) * 50;
      if (mark >= 50) {
        const claim = await db.from('member_milestones').insert({ count: mark }).select('count').single();
        if (!claim.error) {
          const { data: acc } = await db.from('access_list').select('email');
          await tell((acc || []).map((x) => x.email), `\u{1F389} We did it: ${mark} members!`,
            `Time to celebrate! The Wolverine Finance Association just passed ${mark} members, and we're now ${total} strong. \u{1F973}\n\nEvery event you planned, every flyer you posted, and every student you invited got us here. This one belongs to the whole officer team. Thank you!\n\nNext stop: ${mark + 50} members. Let's go! \u{1F680}`,
            'See the members', `${site}/#officer/members`, `members-${mark}`);
          await db.from('change_log').insert({ who: 'automatic emails', text: `Told the officers WFA passed ${mark} members` });
        }
      }
    } catch (_) { /* not set up yet (115-member-milestones.sql) */ }

    // Class visits (see 116-class-visits.sql): remind the officer doing a visit the morning of (7 AM) and again two
    // hours before. A visit nobody has claimed goes to every officer instead. Each reminder is claimed on the visit
    // first so it only goes out once. Works even when the event emails are off.
    try {
      const { data: visits } = await db.from('class_visits').select('*').eq('date', isoDay(Date.now()));
      let everyone: string[] | null = null;
      for (const v of visits || []) {
        const at = Date.now(), start = mtMs(v.date, v.start_time);
        if (at >= start) continue;
        const kind = !v.soon_reminded_at && at >= start - 2 * HOUR ? 'soon'
          : !v.soon_reminded_at && !v.day_reminded_at && at >= mtMs(v.date, '07:00') ? 'day' : '';
        if (!kind) continue;
        const col = kind === 'soon' ? 'soon_reminded_at' : 'day_reminded_at';
        const claim = await db.from('class_visits').update({ [col]: new Date().toISOString() }).eq('id', v.id).is(col, null).select('id');
        if (claim.error || !(claim.data || []).length) continue;
        const what = `${v.course}${v.professor ? ' (' + v.professor + ')' : ''}`, time = fmtTime(start);
        const where = `${time}${v.end_time ? ' to ' + fmtTime(mtMs(v.date, v.end_time)) : ''}${v.room ? ', ' + v.room : ''}`;
        const notes = String(v.notes || '').trim() ? `\n\nNotes: ${String(v.notes).trim()}` : '';
        let to: string[], subject: string, body: string, label = 'See class visits';
        if (v.officer) {
          to = [v.officer];
          subject = kind === 'soon' ? `In 2 hours: class visit to ${v.course}` : `Today at ${time}: class visit to ${v.course}`;
          body = `You're visiting ${what} today.\n\nWhen and where: ${where}${notes}\n\nCan't make it? Give it up in Officer tools -> Class visits so another officer can take it.`;
        } else {
          if (!everyone) { const { data: acc } = await db.from('access_list').select('email'); everyone = (acc || []).map((x) => x.email); }
          to = everyone; label = 'Claim this visit';
          subject = kind === 'soon' ? `Still open, in 2 hours: class visit to ${v.course}` : `Open class visit today: ${v.course} at ${time}`;
          body = `Nobody has claimed today's class visit to ${what} yet.\n\nWhen and where: ${where}${notes}\n\nIf you can go, claim it in Officer tools -> Class visits.`;
        }
        await tell(to, subject, body, label, `${site}/#officer/visits`, `visit-${v.id}-${kind}`);
      }
    } catch (_) { /* not set up yet (116-class-visits.sql) */ }

    // Checklist reminders (see 119-task-reminders.sql): the day before a planning-checklist task is due (from 9 AM),
    // its owner gets one message listing what's due tomorrow, grouped by event. Each task is claimed first so it's
    // only reminded once. Works even when the event emails are off.
    try {
      const nowMs = Date.now(), tomorrow = isoDay(nowMs + DAY);
      if (nowMs >= mtMs(isoDay(nowMs), '09:00')) {
        const claim = await db.from('tasks').update({ reminded_at: new Date().toISOString() }).eq('done', false).eq('due', tomorrow).is('reminded_at', null).select('id, title, owner, event_id');
        const due = claim.error ? [] : (claim.data || []);
        if (due.length) {
          const evIds = [...new Set(due.map((x) => x.event_id).filter(Boolean))];
          const { data: evs } = evIds.length ? await db.from('events').select('id, title').in('id', evIds) : { data: [] };
          const evTitle = new Map((evs || []).map((x) => [x.id, String(x.title || '')]));
          const byOwner = new Map<string, typeof due>();
          due.forEach((x) => { const o = String(x.owner || '').toLowerCase(); if (o) byOwner.set(o, [...(byOwner.get(o) || []), x]); });
          let told = 0;
          for (const [owner, list] of byOwner) {
            const groups = new Map<string, string[]>();
            list.forEach((x) => { const k = evTitle.get(x.event_id) || 'Other tasks'; groups.set(k, [...(groups.get(k) || []), String(x.title)]); });
            const lines = [...groups].map(([ev, items]) => `${ev}:\n` + items.map((i) => `- ${i}`).join('\n')).join('\n\n');
            const subject = list.length === 1 ? `Due tomorrow: ${list[0].title}` : `${list.length} checklist items are due tomorrow`;
            const body = `${list.length === 1 ? 'This checklist item is' : 'These checklist items are'} due tomorrow, ${fmtDay(nowMs + DAY)}:\n\n${lines}\n\nTick ${list.length === 1 ? 'it' : 'them'} off when ${list.length === 1 ? "it's" : "they're"} done, or change the due date if the plan has moved.`;
            if (await tell([owner], subject, body, 'Open the checklist', `${site}/#officer/plan`, `tasks-${tomorrow}`)) told++;
          }
          if (told) await db.from('change_log').insert({ who: 'automatic emails', text: `Reminded ${told} officer${told === 1 ? '' : 's'} about checklist items due tomorrow` });
        }
      }
    } catch (_) { /* not set up yet (119-task-reminders.sql) */ }

    // Waitlists (see 62-rsvp-waitlist.sql): tell people who just got a seat. Works even when the event emails are off.
    const { data: promoted } = await db.from('waitlist').select('event_id, email').not('promoted_at', 'is', null).is('notified_at', null).limit(200);
    if (promoted?.length) {
      const { data: wevs } = await db.from('events').select('id, title, date, start_time, loc').in('id', [...new Set(promoted.map((w) => w.event_id))]);
      const evOf = new Map((wevs || []).map((e) => [e.id, e]));
      const footer = `You're getting this because you joined the waitlist for this event on the Wolverine Finance Association site.`;
      for (const w of promoted) {
        const ev = evOf.get(w.event_id);
        if (ev && !testSet.has(w.email)) {
          const start = mtMs(ev.date, ev.start_time), link = `${site}/#event/${ev.id}`;
          const subject = `You're in: ${ev.title}`;
          const body = `A seat opened up for ${ev.title}, so you're off the waitlist and RSVP'd. It's ${fmtDay(start)} at ${fmtTime(start)}${ev.loc ? ', ' + ev.loc : ''}. Can't make it anymore? Cancel your RSVP on the event page so the next person gets the seat.`;
          const reached = await sendPush(db, pushOn && hasDevice.has(w.email) ? [w.email] : [], subject, `${fmtDay(start)}, ${fmtTime(start)}`, link, `waitlist-${ev.id}`);
          if (!reached.size) await resendBatch([{ to: [w.email], subject, html: htmlEmail(`<p style="margin:0 0 12px">${escHtml(hi(w.email))}</p><p style="margin:0 0 12px">${escHtml(body)}</p>`, { label: 'View the event', url: link }, footer), text: `${hi(w.email)}\n\n${body}\n\nView the event: ${link}` }]);
        }
        await db.from('waitlist').update({ notified_at: new Date().toISOString() }).eq('event_id', w.event_id).eq('email', w.email);
      }
    }

    // Start-of-semester profile check (see 67-profile-reminders.sql): January, May, and August, on the 8th at 10 AM
    // Mountain Time (or the first run after). Claimed in profile_reminders first so it only goes out once.
    if (cfg?.profile_reminders !== false) {
      const p = mtParts(Date.now());
      if ([1, 5, 8].includes(p.month) && (p.day > 8 || (p.day === 8 && p.hour >= 10))) {
        const period = `${p.year}-${String(p.month).padStart(2, '0')}`;
        const claim = await db.from('profile_reminders').insert({ period }).select('period').single();
        if (!claim.error) {
          const season = p.month === 1 ? 'spring' : p.month === 5 ? 'summer' : 'fall';
          const link = `${site}/#account`, subject = `New semester: update your WFA profile`;
          const body = `A new ${season} semester is starting! Take a minute to make sure your WFA profile is up to date, so we can match you with the right events, firms, and opportunities:\n\n- Your year in school\n- Your majors and minor\n- The finance careers you're interested in\n- Your resume, and whether to include it in the resume book we share with recruiters`;
          const to = real((members || []).map((m) => m.email));
          const reached = await sendPush(db, to.filter((e) => pushOn && hasDevice.has(e)), subject, 'Check your year, majors, career interests, and resume.', link, `profile-${period}`);
          const viaEmail = to.filter((e) => !reached.has(e) && (byEmail.get(e) || {}).email_opt_in !== false);
          const footer = `You're getting this because you're a Wolverine Finance Association member. To stop these emails, turn off club emails in My account: <a href="${link}" style="color:#1f4d2e">${link}</a>`;
          let sent = reached.size;
          for (let i = 0; i < viaEmail.length; i += 100) {
            const chunk = viaEmail.slice(i, i + 100);
            const r = await resendBatch(chunk.map((e) => ({ to: [e], subject,
              html: htmlEmail(`<p style="margin:0 0 12px">${escHtml(hi(e))}</p><p style="margin:0 0 12px;white-space:pre-wrap">${escHtml(body)}</p>`, { label: 'Update my profile', url: link }, footer),
              text: `${hi(e)}\n\n${body}\n\nUpdate my profile: ${link}` })));
            if (r.ok) sent += chunk.length;
            await new Promise((res) => setTimeout(res, 600));
          }
          await db.from('profile_reminders').update({ sent }).eq('period', period);
        }
      }
    }

    // Emails sent automatically in the last 24 hours, one per person (the daily limit, a safety net).
    const sentToday = async () => {
      const since = new Date(Date.now() - DAY).toISOString();
      const { data: a } = await db.from('auto_email_log').select('emails').gte('sent_at', since);
      const { data: b } = await db.from('survey_reminder_log').select('emails').gte('sent_at', since);
      const { data: c } = await db.from('job_digest_log').select('emails').gte('sent_at', since);
      return [...(a || []), ...(b || []), ...(c || [])].reduce((n: number, r: { emails: number }) => n + (r.emails || 0), 0);
    };

    // Survey reminders (see 74-survey-reminders.sql): the times an officer picked for an open survey, to members who
    // haven't answered. Each is claimed in survey_reminder_log first so it only goes out once. Works even when the event
    // emails are off, since an officer scheduled each one by hand.
    const { data: openSurveys } = await db.from('surveys').select('id, title, closes_at, created_by, questions, remind_at').eq('status', 'open');
    for (const sv of openSurveys || []) {
      const at = Date.now(), times: number[] = (sv.remind_at || []).map((t: string) => Date.parse(t));
      if (!times.length || testSet.has(sv.created_by) || (sv.closes_at && Date.parse(sv.closes_at) <= at)) continue;
      const { data: past } = await db.from('survey_reminder_log').select('remind_at').eq('survey_id', sv.id);
      const last = Math.max(0, ...(past || []).map((l: { remind_at: string }) => Date.parse(l.remind_at)));
      const due = times.filter((t) => t <= at && t >= at - STALE && t > last);
      if (!due.length) continue;
      const claim = await db.from('survey_reminder_log').insert({ survey_id: sv.id, remind_at: new Date(Math.max(...due)).toISOString() }).select('id').single();
      if (claim.error) continue;
      const finish = (row: Record<string, unknown>) => db.from('survey_reminder_log').update(row).eq('id', claim.data.id);

      const { data: answered } = await db.from('survey_responses').select('email').eq('survey_id', sv.id);
      const { data: rules } = await db.from('point_rules').select('points, deadline').eq('kind', 'form').eq('survey_id', sv.id);
      const { data: staff } = await db.from('access_list').select('email');
      const done = new Set((answered || []).map((r: { email: string }) => r.email)), unranked = new Set((staff || []).map((r: { email: string }) => r.email));
      const yearOf = (e: string) => String((byEmail.get(e) || {}).year || '');
      // Skip anyone whose year has no questions in this survey.
      const sees = (e: string) => !yearOf(e) || (sv.questions || []).some((q: SurveyQ) => !(q.years || []).length || (q.years || []).includes(yearOf(e)));
      const to = real((members || []).map((m) => m.email)).filter((e) => !done.has(e) && sees(e));
      const copy = (e: string) => surveyReminderCopy(sv, rules || [], yearOf(e), !unranked.has(e), at);
      const link = `${site}/#survey/${sv.id}`;

      // Notifications first, grouped by how many points they mention; anyone they don't reach can get the email.
      const reached = new Set<string>(), groups = new Map<number, string[]>();
      for (const e of to.filter((x) => getsPush(x, 'surveys'))) groups.set(copy(e).most, [...(groups.get(copy(e).most) || []), e]);
      for (const [most, list] of groups) {
        const got = await sendPush(db, list, `Reminder: ${sv.title}`, most ? `Earn up to ${most} leaderboard ${most === 1 ? 'point' : 'points'}.` : 'It only takes a few minutes.', link, `survey-remind-${sv.id}`);
        got.forEach((e) => reached.add(e));
      }
      const viaEmail = to.filter((e) => !reached.has(e) && (byEmail.get(e) || {}).email_opt_in !== false && choice(e, 'surveys_email'));
      if (!to.length) { await finish({ status: 'skipped', detail: 'Everyone has answered' }); continue; }
      const cap = Math.max(0, Math.min(5000, Number(cfg?.daily_cap ?? 500)));
      if (await sentToday() + viaEmail.length > cap) { await finish({ status: 'skipped', recipients: reached.size, detail: `Daily limit of ${cap} automatic emails reached` }); continue; }

      const footer = `You're getting this because you're a Wolverine Finance Association member and haven't answered this survey yet. To stop these emails, turn off club emails in My account: <a href="${site}/#account" style="color:#1f4d2e">${site}/#account</a>`;
      let ok = 0, fail = 0, note = '';
      for (let i = 0; i < viaEmail.length; i += 100) {
        const chunk = viaEmail.slice(i, i + 100);
        const r = await resendBatch(chunk.map((e) => { const c = copy(e); return { to: [e], subject: c.subject,
          html: htmlEmail(`<p style="margin:0 0 12px">${escHtml(hi(e))}</p><p style="margin:0 0 12px">${escHtml(c.body)}</p>`, { label: 'Take the survey', url: link }, footer),
          text: `${hi(e)}\n\n${c.body}\n\nTake the survey: ${link}` }; }));
        if (r.ok) ok += chunk.length; else { fail += chunk.length; note = r.detail; }
        await new Promise((res) => setTimeout(res, 600));
      }
      await finish({ status: ok || reached.size || !fail ? 'sent' : 'failed', recipients: reached.size + ok, emails: ok + fail, detail: note.slice(0, 500) });
    }

    // Job openings (98-job-openings-email.sql): Mondays at 9 AM Mountain Time (or the first run after, that day).
    // Each person gets up to 12 listings that have never been emailed, picked like the newsletter's job picks.
    // Claimed in job_digest_log first so it only goes out once a week. Works even when the event emails are off.
    if (cfg?.jobs_weekly !== false) {
      const p = mtParts(Date.now()), dow = new Date(Date.UTC(p.year, p.month - 1, p.day)).getUTCDay();
      if (dow === 1 && p.hour >= 9) {
        const week = isoDay(Date.now());
        const claim = await db.from('job_digest_log').insert({ week }).select('week').single();
        if (!claim.error) {
          const finish = (row: Record<string, unknown>) => db.from('job_digest_log').update(row).eq('week', week);
          const today = isoDay(Date.now());
          const { data: jobRows } = await db.from('job_postings').select('id, kind, company, title, url, opens_on, closes_on, careers, states, remote, created_at').is('mailed_at', null).neq('kind', 'employer');
          const { data: careerRows } = await db.from('careers').select('id, title');
          const { data: firmRows } = await db.from('notable_firms').select('name, kind, aliases');
          type JobRow = { id: string; kind: string; company: string; title: string; url: string; opens_on: string | null; closes_on: string | null; careers: string[]; states: string[]; remote: boolean; created_at: string };
          const open = ((jobRows || []) as JobRow[]).filter((j) => (!j.closes_on || j.closes_on >= today) && (!j.opens_on || j.opens_on <= today));
          const careerName = new Map((careerRows || []).map((c) => [c.id, c.title]));
          const norm = (x: string) => ' ' + String(x || '').toLowerCase().replace(/&/g, ' and ').replace(/[^a-z0-9]+/g, ' ').trim() + ' ';
          const firmList = (firmRows || []).map((f) => ({ kind: f.kind as string, names: [f.name, ...(f.aliases || [])].filter(Boolean).map(norm) }));
          const firmKind = new Map<string, string>();
          const kindOf = (company: string) => { if (!firmKind.has(company)) { const c = norm(company); firmKind.set(company, (firmList.find((f) => f.names.some((n) => c.includes(n))) || { kind: '' }).kind); } return firmKind.get(company)!; };
          const bigName = (j: JobRow) => ['wall_street', 'buy_side', 'big4', 'consulting', 'big_company'].includes(kindOf(j.company));
          const utah = (j: JobRow) => (j.states || []).includes('UT') || kindOf(j.company) === 'utah';
          const kindsFor = (year: string) => year === 'Senior' ? ['full_time'] : year === 'Graduate student' ? ['full_time', 'internship']
            : ['Freshman', 'Sophomore', 'Junior'].includes(year) ? ['internship'] : ['internship', 'full_time'];
          const picksFor = (m: { year?: string; interests?: string[]; job_focus?: string }) => {
            const kinds = kindsFor(m.year || ''), likes = new Set(m.interests || []), focus = m.job_focus || 'both';
            const score = (j: JobRow) => ((likes.size && (j.careers || []).some((c) => likes.has(careerName.get(c) || '')) ? 100 : 0)
              + (kinds.length > 1 && j.kind === kinds[0] ? 40 : 0) + (({ wall_street: 25, buy_side: 25, big4: 20, consulting: 20, big_company: 18 } as Record<string, number>)[kindOf(j.company)] || 0)
              + (utah(j) ? 10 : 0) + (focus === 'big' && bigName(j) ? 60 : focus === 'utah' && utah(j) ? 60 : 0));
            const list = open.filter((j) => kinds.includes(j.kind)).map((j) => [j, score(j)] as [JobRow, number])
              .sort((a, b) => b[1] - a[1] || String(b[0].created_at).localeCompare(String(a[0].created_at)));
            // An even spread across career paths: one from each of their career interests in turn (or every career
            // path, if they have none), best-scored first, then any open spots in score order. At most 2 per company.
            const sorted = list.map(([j]) => j), careersOf = (j: JobRow) => (j.careers || []).map((c) => careerName.get(c) || '').filter(Boolean);
            const keys = likes.size ? [...likes] : [...new Set(sorted.flatMap(careersOf))];
            const buckets = keys.map((k) => sorted.filter((j) => careersOf(j).includes(k))), at = buckets.map(() => 0);
            const per: Record<string, number> = {}, out: JobRow[] = [], seen = new Set<string>();
            const take = (j: JobRow) => { const k = j.company.toLowerCase(); if (seen.has(j.id) || (per[k] || 0) >= 2) return false; per[k] = (per[k] || 0) + 1; seen.add(j.id); out.push(j); return true; };
            for (let more = true; more && out.length < 12;) {
              more = false;
              buckets.forEach((b, i) => { if (out.length >= 12) return; while (at[i] < b.length) if (take(b[at[i]++])) { more = true; break; } });
            }
            for (const j of sorted) { if (out.length >= 12) break; take(j); }
            return out;
          };
          const people = real((members || []).filter((m) => m.email_opt_in !== false).map((m) => m.email))
            .map((e) => [e, picksFor(byEmail.get(e) || {})] as [string, JobRow[]]).filter(([, l]) => l.length);
          const cap = Math.max(0, Math.min(5000, Number(cfg?.daily_cap ?? 500)));
          if (!people.length) await finish({ status: 'skipped', detail: open.length ? 'Nobody had new matches' : 'No new listings this week' });
          else if (await sentToday() + people.length > cap) await finish({ status: 'skipped', detail: `Daily limit of ${cap} automatic emails reached` });
          else {
            const subject = `WFA Job Openings - ${new Intl.DateTimeFormat('en-US', { timeZone: TZ, month: 'long', day: 'numeric' }).format(new Date())}`;
            const link = `${site}/#jobs`, KIND: Record<string, string> = { internship: 'Internship', full_time: 'Full-time' };
            const dayOf = (d: string) => fmtDay(mtMs(d, '12:00'));
            const where = (j: JobRow) => [...(j.states || []), ...(j.remote ? ['Remote'] : [])].join(', ');
            const meta = (j: JobRow) => [KIND[j.kind] || '', where(j), j.closes_on ? 'Apply by ' + dayOf(j.closes_on) : ''].filter(Boolean).join(' - ');
            const chip = (x: string, c: string) => `<span style="display:inline-block;margin-left:6px;padding:1px 7px;border-radius:9px;background:${c};font-size:11px;font-weight:bold;color:#ffffff">${x}</span>`;
            const card = (j: JobRow) => `<tr><td style="padding:10px 0;border-bottom:1px solid #e3e0d6"><div style="font-weight:bold">${escHtml(j.company)}${bigName(j) ? chip('Big name', '#8a6a1f') : ''}${utah(j) ? chip('Utah', '#1f4d2e') : ''}</div>` +
              `<div style="margin:2px 0"><a href="${escHtml(j.url)}" style="color:#1f4d2e;font-weight:bold">${escHtml(j.title)}</a></div><div style="font-size:13px;color:#5e6b60">${escHtml(meta(j))}</div></td></tr>`;
            const intro = 'Here are new finance openings picked for you. Many firms hire on a rolling basis, so apply early.';
            const footer = `You're getting this because you're a Wolverine Finance Association member. Change your year, career interests, and job picks in My account, or turn off club emails there: <a href="${site}/#account" style="color:#1f4d2e">${site}/#account</a>`;
            let ok = 0, fail = 0, last = '';
            const used = new Set<string>();
            for (let i = 0; i < people.length; i += 100) {
              const chunk = people.slice(i, i + 100);
              const r = await resendBatch(chunk.map(([e, l]) => ({ to: [e], subject,
                html: htmlEmail(`<p style="margin:0 0 12px">${escHtml(hi(e))}</p><p style="margin:0 0 12px">${escHtml(intro)}</p><table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0">${l.map(card).join('')}</table>`, { label: 'See every opening', url: link }, footer),
                text: `${hi(e)}\n\n${intro}\n\n` + l.map((j) => `- ${j.company}: ${j.title} (${meta(j)})\n  ${j.url}`).join('\n') + `\n\nSee every opening: ${link}`,
                tags: [{ name: 'campaign', value: 'jobs-' + week }] })));
              if (r.ok) { ok += chunk.length; chunk.forEach(([, l]) => l.forEach((j) => used.add(j.id))); } else { fail += chunk.length; last = r.detail; }
              await new Promise((res) => setTimeout(res, 600));
            }
            const ids = [...used];
            for (let i = 0; i < ids.length; i += 100) await db.from('job_postings').update({ mailed_at: new Date().toISOString() }).in('id', ids.slice(i, i + 100)).is('mailed_at', null);
            await finish({ status: ok ? 'sent' : 'failed', recipients: ok, emails: ok + fail, jobs: ids.length, detail: fail ? `${fail} failed: ${last}`.slice(0, 500) : '' });
            if (ok) await db.from('change_log').insert({ who: 'automatic emails', text: `Sent the Job openings email (${ids.length} listings) to ${ok} ${ok === 1 ? 'person' : 'people'}` });
          }
        }
      }
    }

    if (!cfg?.enabled) return json({ ok: true, sent: 0, chat_alerts: chatAlerts, scheduling: schedNotes, note: 'Automatic emails are off.' });
    const now = Date.now();

    let used = await sentToday();
    const cap = Math.max(0, Math.min(5000, Number(cfg.daily_cap ?? 500)));

    const { data: events } = await db.from('events').select('id, title, cat, date, start_time, end_time, loc, descr, draft, test, reg_mode, dress_code, dress_note, qa_enabled, speakers')
      .eq('draft', false).eq('test', false).neq('cat', 'officer_meeting')
      .gte('date', isoDay(now - 2 * DAY)).lte('date', isoDay(now + 8 * DAY));
    if (!events?.length) return json({ ok: true, sent: 0, chat_alerts: chatAlerts });
    const ids = events.map((e) => e.id);
    const { data: done } = await db.from('auto_email_log').select('event_id, kind').in('event_id', ids);
    const already = new Set((done || []).map((r) => r.event_id + '|' + r.kind));
    type Role = { phase: string; name: string; arrive: number; qty: number; duties: string; officers: string[] };
    const { data: roleRows } = await db.from('event_roles').select('event_id, roles').in('event_id', ids);
    const rolesBy = new Map<string, Role[]>((roleRows || []).map((x) => [x.event_id, (Array.isArray(x.roles) ? x.roles : []).filter((r: Role) => r && r.name)] as [string, Role[]]));
    const crewAll = [...new Set([...rolesBy.values()].flat().flatMap((r) => r.officers || []))];
    const { data: crewPeople } = crewAll.length ? await db.from('members').select('email, first, last').in('email', crewAll) : { data: [] };
    const crewName = new Map((crewPeople || []).map((p) => [p.email, `${p.first || ''} ${p.last || ''}`.trim()]));
    const nameOf = (email: string) => crewName.get(email) || email.split('@')[0];

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
      html: (greeting: string, email: string) => string; text: (greeting: string, email: string) => string; push: { title: string; body: string; url: string } };
    const jobs: Job[] = [];
    for (const ev of events) {
      if (ev.reg_mode === 'link') continue;   // another organization's event: no WFA reminders or check-in (82-simpler-event-approvals.sql)
      const start = mtMs(ev.date, ev.start_time), end = mtMs(ev.date, ev.end_time);
      const link = `${site}/#event/${ev.id}`, when = `${fmtDay(start)}, ${fmtTime(start)} to ${fmtTime(end)}`;
      const footer = `You're getting this because you're a Wolverine Finance Association member or asked for reminders about this event. Members can change which emails they get in Notification settings on the site, or turn club emails off in My account: <a href="${site}/#account" style="color:#1f4d2e">${site}/#account</a>`;
      const details = `<p style="margin:0 0 4px"><strong>${escHtml(ev.title)}</strong></p><p style="margin:0 0 4px">${escHtml(when)}</p>` +
        (ev.loc ? `<p style="margin:0 0 12px">${escHtml(ev.loc)}</p>` : '') +
        (ev.descr ? `<div style="margin:0 0 6px 18px;color:#3d4a40;white-space:pre-wrap">${escHtml(ev.descr)}</div>` : '');
      // Dress code: one line in every reminder; the day before also gets what to wear and, for bigger events, networking tips.
      const dc = DRESS[ev.dress_code || ''], dnote = String(ev.dress_note || '').trim();
      const dressShort = dc || dnote ? [dc ? dc[0] : '', dnote].filter(Boolean).join('. ') : '';
      const prepHtml = () => dressHtml() + tipsHtml();
      const tipsHtml = () => { const tips = PREP[ev.cat];
        return tips ? `<p style="margin:16px 0 4px"><strong>Networking tips</strong></p><ul style="margin:0 0 6px;padding-left:20px">${tips.map((x) => `<li>${escHtml(x)}</li>`).join('')}</ul>` : ''; };
      const dressHtml = () => {
        let h = '';
        if (dc || dnote) h += `<p style="margin:16px 0 4px"><strong>What to wear${dc ? ': ' + escHtml(dc[0]) : ''}</strong></p>` +
          (dc ? `<p style="margin:0 0 6px">${escHtml(dc[1])}</p>` : '') +
          (dc && dc[2].length ? `<ul style="margin:0 0 6px;padding-left:20px">${dc[2].map(([w, x]) => `<li><strong>${escHtml(w)}:</strong> ${escHtml(x)}</li>`).join('')}</ul>` : '') +
          (dnote ? `<p style="margin:0 0 6px">${escHtml(dnote)}</p>` : '');
        return h;
      };
      const prepText = () => dressText() + tipsText();
      const dressText = () => (dc || dnote) ? `\n\nWHAT TO WEAR${dc ? ': ' + dc[0] + '. ' + dc[1] : ''}` + (dc ? dc[2].map(([w, x]) => `\n- ${w}: ${x}`).join('') : '') + (dnote ? `\n${dnote}` : '') : '';
      const tipsText = () => { const tips = PREP[ev.cat]; return tips ? `\n\nNETWORKING TIPS` + tips.map((x) => `\n- ${x}`).join('') : ''; };

      // Officer roles: each officer on one gets their own email the day before (instead of the regular day-before
      // reminder), with what to do, when to arrive, and who's doing what. Roles saved later that day still go out,
      // up to 3 hours before the start.
      const roles = rolesBy.get(ev.id) || [];
      const crew = [...new Set(roles.flatMap((r) => r.officers || []))].filter((e) => !testSet.has(e));
      let crewOut = crew.length > 0 && already.has(ev.id + '|crew_1d');
      if (crew.length && !crewOut && now >= start - DAY && now < start - 3 * HOUR) {
        crewOut = true;
        const PHASES: [string, string][] = [['before', 'Before people arrive'], ['during', 'During the event'], ['after', 'After the event']];
        const at = (r: Role) => fmtTime(start - (Number(r.arrive) || 0) * 60000);
        const early = (r: Role) => Number(r.arrive) ? `${at(r)}, ${r.arrive} minutes early` : `${at(r)}, when it starts`;
        const mine = (email: string) => roles.filter((r) => (r.officers || []).includes(email));
        const arriveBy = (email: string) => fmtTime(start - Math.max(0, ...mine(email).map((r) => Number(r.arrive) || 0)) * 60000);
        const who = (r: Role) => { const n = (r.officers || []).map(nameOf), open = Math.max(0, (Number(r.qty) || 1) - n.length);
          return [n.join(', '), open ? `${open} open` : ''].filter(Boolean).join(', '); };
        const crewHtml = PHASES.map(([p, label]) => { const l = roles.filter((r) => r.phase === p); return l.length ? `<p style="margin:10px 0 2px;color:#3d4a40"><em>${label}</em></p><ul style="margin:0 0 6px;padding-left:20px">${l.map((r) => `<li><strong>${escHtml(r.name)}</strong> (${escHtml(at(r))}): ${escHtml(who(r))}</li>`).join('')}</ul>` : ''; }).join('');
        const crewText = PHASES.map(([p, label]) => { const l = roles.filter((r) => r.phase === p); return l.length ? `\n\n${label}:` + l.map((r) => `\n- ${r.name} (${at(r)}): ${who(r)}`).join('') : ''; }).join('');
        const crewFooter = `You're getting this because you're on an officer role for this event. See or change the roles on the event page: <a href="${link}" style="color:#1f4d2e">${link}</a>`;
        jobs.push({ ev, kind: 'crew_1d', subject: `Tomorrow: your role at ${ev.title}`, emailTo: crew, pushTo: [],
          html: (g, email) => htmlEmail(`<p style="margin:0 0 12px">${escHtml(g)}</p><p style="margin:0 0 12px">Thanks for helping with ${escHtml(ev.title)} tomorrow! Please arrive by <strong>${escHtml(arriveBy(email))}</strong>.</p>` +
            mine(email).map((r) => `<p style="margin:12px 0 4px"><strong>Your role: ${escHtml(r.name)}</strong> (arrive by ${escHtml(early(r))})</p>` + (r.duties ? `<p style="margin:0 0 6px;white-space:pre-wrap">${escHtml(r.duties)}</p>` : '')).join('') +
            `<p style="margin:16px 0 4px"><strong>Who's doing what</strong></p>${crewHtml}<p style="margin:16px 0 8px"><strong>The event</strong></p>${details}${dressHtml()}`, { label: 'View the event', url: link }, crewFooter),
          text: (g, email) => `${g}\n\nThanks for helping with ${ev.title} tomorrow! Please arrive by ${arriveBy(email)}.` +
            mine(email).map((r) => `\n\nYOUR ROLE: ${r.name} (arrive by ${early(r)})` + (r.duties ? `\n${r.duties}` : '')).join('') +
            `\n\nWHO'S DOING WHAT${crewText}\n\nTHE EVENT\n${when}\n${ev.loc || ''}` + dressText() + `\n\nView the event: ${link}`,
          push: { title: '', body: '', url: link } });
      }
      const crewSet = new Set(crewOut ? crew : []);

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
        const label = toEveryone && ev.reg_mode !== 'none' ? 'View the event and RSVP' : 'View the event';
        // Guests who RSVP'd without an account and asked for reminders about this event.
        let guestTo: string[] = [];
        if (ev.cat !== 'case_competition') {
          const { data: gr } = await db.from('guest_rsvps').select('email, first').eq('event_id', ev.id).eq('reminders', true);
          (gr || []).forEach((g) => { if (!byEmail.has(g.email)) { guestTo.push(g.email); firstName.set(g.email, String(g.first || '').trim()); } });
          guestTo = [...new Set(guestTo)];
        }
        // Day of: people whose question was starred (picked to be asked) get it back, with a heads-up that the host will call on
        // them to ask it themselves (so the speaker can see who's asking).
        const asked = new Map<string, string[]>();
        if (r.key === 'same' && ev.qa_enabled) {
          const { data: qs } = await db.from('event_questions').select('email, question, created_at').eq('event_id', ev.id).eq('starred', true).not('email', 'is', null).order('created_at');
          (qs || []).forEach((q) => { const e = String(q.email).toLowerCase(); asked.set(e, [...(asked.get(e) || []), String(q.question)]); });
        }
        const sp = Array.isArray(ev.speakers) ? ev.speakers.map((x: { name?: string }) => String(x?.name || '').trim()).filter(Boolean) : [];
        const spName = sp.length === 1 ? sp[0] : sp.length ? 'the speakers' : 'the speaker';
        const qaNote = `Your question was picked for the Q&A. The emcee will call on you to ask your question yourself, so ${spName} can see who's asking. It's a great chance to introduce yourself and make a connection, so have ${'{n}'} ready:`;
        const qaHtml = (email: string) => { const l = asked.get(email); return l ? `<div style="margin:16px 0 6px;padding:12px 14px;background:#f3f6f1;border-left:3px solid #1f4d2e"><p style="margin:0 0 6px"><strong>Get ready to be called on</strong></p><p style="margin:0 0 6px">${escHtml(qaNote.replace('{n}', l.length === 1 ? 'it' : 'them'))}</p><ul style="margin:0;padding-left:20px">${l.map((q) => `<li style="margin:0 0 4px">${escHtml(q)}</li>`).join('')}</ul></div>` : ''; };
        const qaText = (email: string) => { const l = asked.get(email); return l ? `\n\nGET READY TO BE CALLED ON\n${qaNote.replace('{n}', l.length === 1 ? 'it' : 'them')}` + l.map((q) => `\n- ${q}`).join('') : ''; };
        const askers = real([...asked.keys()]).filter((e) => byEmail.has(e) && getsEmail(e, 'events'));
        const emailTo = [...new Set([...base.filter((e) => getsEmail(e, 'events') && !(r.key === '1d' && crewSet.has(e))), ...guestTo, ...askers])];
        jobs.push({ ev, kind, subject, emailTo, pushTo: base.filter((e) => getsPush(e, 'events')),
          html: (g, email) => htmlEmail(`<p style="margin:0 0 12px">${escHtml(g)}</p><p style="margin:0 0 16px">${escHtml(lead)}</p>${qaHtml(email)}${details}` +
            (r.key === '1d' ? prepHtml() : dressShort ? `<p style="margin:0 0 6px"><strong>Dress:</strong> ${escHtml(dressShort)}</p>` : ''), { label, url: link }, footer),
          text: (g, email) => `${g}\n\n${lead}${qaText(email)}\n\n${when}\n${ev.loc || ''}\n\n${ev.descr || ''}` +
            (r.key === '1d' ? prepText() : dressShort ? `\n\nDress: ${dressShort}` : '') + `\n\n${label}: ${link}`,
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
      // A second nudge when the event starts, to people signed up who still haven't checked in. Only after the
      // 15-minute one went out on an earlier run, so nobody gets both at once.
      if (pushOn && already.has(ev.id + '|checkin_open') && !already.has(ev.id + '|checkin_start') && now >= start && now < end) {
        const { data: att } = await db.from('attendance').select('email').eq('event_id', ev.id);
        const here = new Set((att || []).map((x) => x.email));
        const base = real(await signedUp(ev)).filter((e) => !here.has(e));
        jobs.push({ ev, kind: 'checkin_start', subject: '', emailTo: [], pushTo: base.filter((e) => getsPush(e, 'checkin')),
          html: () => '', text: () => '', push: { title: `Starting now: ${ev.title}`, body: 'You haven\'t checked in yet. Tap to check in with the code on screen.', url: link } });
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
      const pushed = (await sendPush(db, j.pushTo, j.push.title, j.push.body, j.push.url, `${j.kind}-${j.ev.id}`)).size;
      if (!j.emailTo.length) {
        await db.from('auto_email_log').update({ status: pushed ? 'sent' : 'skipped', detail: pushed ? `Notified ${pushed} ${pushed === 1 ? 'person' : 'people'}; no emails needed` : 'Nobody to send to' }).eq('id', id);
        continue;
      }
      if (used + j.emailTo.length > cap) { await db.from('auto_email_log').update({ status: 'skipped', detail: `Daily limit of ${cap} automatic emails reached` }).eq('id', id); continue; }
      let ok = 0, fail = 0, last = '';
      for (let i = 0; i < j.emailTo.length; i += 100) {
        const chunk = j.emailTo.slice(i, i + 100);
        const r = await resendBatch(chunk.map((email) => ({ to: [email], subject: j.subject, html: j.html(hi(email), email), text: j.text(hi(email), email), tags: [{ name: 'campaign', value: 'auto-' + id }] })));
        if (r.ok) ok += chunk.length; else { fail += chunk.length; last = r.detail; }
        await new Promise((res) => setTimeout(res, 600));   // stay under Resend's rate limit
      }
      used += ok + fail;
      const note = [pushed ? `also notified ${pushed} ${pushed === 1 ? 'person' : 'people'}` : '', fail ? `${fail} of ${ok + fail} people didn't get it: ${last}` : ''].filter(Boolean).join('; ');
      await db.from('auto_email_log').update({ status: ok ? 'sent' : 'failed', emails: ok + fail, detail: note.slice(0, 500) }).eq('id', id);
      await db.from('change_log').insert({ who: 'automatic emails', text: `Sent "${j.subject}" to ${j.emailTo.length} ${j.emailTo.length === 1 ? 'person' : 'people'}${fail ? ' (some failed)' : ''}` });
      results.push(j.kind);
    }
    return json({ ok: true, sent: results.length, chat_alerts: chatAlerts, scheduled });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
