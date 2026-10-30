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
//   * a start-of-semester reminder to update your profile, in January, May, and August (see 67-profile-reminders.sql)
//   * (not an email) applies the automatic leaderboard point rules each run (see 56-point-rules.sql)
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
    const { data: reqs } = await db.from('event_requests').select('event_id, status, status_by, note, signoff_note, sent_by, sent_at, status_at, nudged_at, branch, votes, history').in('status', ['branch', 'review', 'sent', 'returned', 'submitted', 'approved', 'signoff', 'published']);
    if (reqs?.length) {
      const { data: evs } = await db.from('events').select('id, title, cat, date').in('id', reqs.map((r) => r.event_id));
      const titleOf = new Map((evs || []).map((e) => [e.id, e.title])), evOf = new Map((evs || []).map((e) => [e.id, e]));
      const BIG = ['case_competition', 'excursion', 'guest_speaker', 'career_fair'];
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

    if (!cfg?.enabled) return json({ ok: true, sent: 0, chat_alerts: chatAlerts, scheduling: schedNotes, note: 'Automatic emails are off.' });
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
        const r = await resendBatch(chunk.map((email) => ({ to: [email], subject: j.subject, html: j.html(hi(email)), text: j.text(hi(email)) })));
        if (r.ok) ok += chunk.length; else { fail += chunk.length; last = r.detail; }
        await new Promise((res) => setTimeout(res, 600));   // stay under Resend's rate limit
      }
      used += ok + fail;
      const note = [pushed ? `also notified ${pushed} ${pushed === 1 ? 'person' : 'people'}` : '', fail ? `${fail} of ${ok + fail} people didn't get it: ${last}` : ''].filter(Boolean).join('; ');
      await db.from('auto_email_log').update({ status: ok ? 'sent' : 'failed', emails: ok + fail, detail: note.slice(0, 500) }).eq('id', id);
      await db.from('change_log').insert({ who: 'automatic emails', text: `Sent "${j.subject}" to ${j.emailTo.length} ${j.emailTo.length === 1 ? 'person' : 'people'}${fail ? ' (some failed)' : ''}` });
      results.push(j.kind);
    }
    return json({ ok: true, sent: results.length, chat_alerts: chatAlerts });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
