// Offline tests for supabase/2-invite-officer.ts. Run from the repo root:  node supabase/test/invite-officer.test.mjs
// Needs Node 22.18+ (it strips the TypeScript types). Supabase, Resend and Deno are mocked: nothing is sent.
import { readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';

const SRC = fileURLToPath(new URL('../2-invite-officer.ts', import.meta.url));
const OUT = join(tmpdir(), 'invite-officer-under-test.mts');
let code = readFileSync(SRC, 'utf8').replace(
  "import { createClient } from 'npm:@supabase/supabase-js@2';",
  'const createClient = (...a: any[]) => (globalThis as any).__mockClient(...a);'
);
writeFileSync(OUT, code);

let handler;
let ENV = {};
globalThis.Deno = { env: { get: (k) => ENV[k] }, serve: (h) => { handler = h; } };

// ---- mock state ----
let S;
function reset(over = {}) {
  S = {
    callerEmail: 'admin@uvu.edu', getUserError: null,
    access: { 'admin@uvu.edu': 'admin' }, members: {}, profiles: {}, log: [], users: [],
    resendCalls: [], resendStatus: 200, resendBody: '{"id":"x"}',
    genLinkError: null, otp: '123456',
    ...over,
  };
}
globalThis.__mockClient = () => ({
  auth: {
    getUser: async (t) => S.getUserError ? { data: { user: null }, error: S.getUserError } : (t === 'good' ? { data: { user: { email: S.callerEmail } }, error: null } : { data: { user: null }, error: { status: 401, message: 'bad jwt' } }),
    admin: {
      createUser: async (p) => { S.users.push(p); S.members[p.email] = { id: 'u-' + p.email }; return { error: null }; },
      updateUserById: async (id, p) => { S.users.push({ id, ...p }); return { error: null }; },
      getUserById: async (id) => ({ data: { user: { id, last_sign_in_at: (S.signedIn||{})[id] ? '2026-10-01T00:00:00Z' : null, email_confirmed_at: (S.unconfirmed||{})[id] ? null : '2026-09-01T00:00:00Z' } }, error: null }),
      generateLink: async (p) => S.genLinkError ? { data: null, error: { message: S.genLinkError } } : { data: { properties: { email_otp: S.otp } }, error: null },
    },
  },
  from: (t) => {
    const q = { t, filters: {} };
    const api = {
      select: () => api,
      eq: (k, v) => { q.filters[k] = v; return api; },
      maybeSingle: async () => {
        if (t === 'access_list') { const r = S.access[q.filters.email]; return { data: r ? { role: r } : null }; }
        if (t === 'members') { return { data: S.members[q.filters.email] || null }; }
        if (t === 'officer_profiles') { return { data: S.profiles[q.filters.email] || null }; }
        return { data: null };
      },
      upsert: async (row) => { if (t === 'access_list') S.access[row.email] = row.role; if (t === 'officer_profiles') S.profiles[row.email] = row; return { error: null }; },
      insert: async (row) => { if (t === 'change_log') S.log.push(row.text); return { error: null }; },
      update: () => ({ eq: async () => ({ error: null }) }),
    };
    return api;
  },
});
globalThis.fetch = async (url, init) => {
  S.resendCalls.push({ url, body: JSON.parse(init.body), headers: init.headers });
  return new Response(S.resendBody, { status: S.resendStatus });
};

await import(pathToFileURL(OUT).href);
const call = async (body, { token = 'good', origin } = {}) => {
  const h = { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' };
  if (origin) h.origin = origin;
  const r = await handler(new Request('https://x/functions/v1/invite-officer', { method: 'POST', headers: h, body: JSON.stringify(body) }));
  return { status: r.status, j: await r.json() };
};
const ENV_OK = { RESEND_API_KEY: 're_test', MAIL_FROM: 'Wolverine Finance Association <noreply@wolverinefinanceassociation.org>', SITE_URL: 'https://wolverinefinanceassociation.org', SUPABASE_URL: 'https://p.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'k' };
const base = { email: 'New.Officer@UVU.edu', first: 'Ann', last: 'Lee', role: 'officer', title: 'Communications Officer', tier: 'officer', branch: 'communications' };
let n = 0; const ok = (m) => console.log('PASS', ++n, m);

// 1. invite, new account: one email, code inside, link to #code, version in reply
ENV = { ...ENV_OK }; reset();
let r = await call({ ...base, mode: 'invite', password: '', send: true });
assert.equal(r.status, 200); assert.equal(r.j.emailed, true); assert.equal(r.j.version, '2026-10-07'); assert.equal(r.j.mode, 'invite');
assert.equal(S.resendCalls.length, 1); let m = S.resendCalls[0];
assert.equal(m.url, 'https://api.resend.com/emails'); assert.deepEqual(m.body.to, ['new.officer@uvu.edu']);
assert.match(m.body.text, /Your setup code: 123456/); assert.match(m.body.text, /https:\/\/wolverinefinanceassociation\.org\/#code/);
assert.match(m.body.text, /Email me a new code/); assert.match(m.body.html, /<a href="https:\/\/wolverinefinanceassociation\.org\/#code"/);
assert.equal(m.body.from, ENV_OK.MAIL_FROM); assert.ok(S.users[0].email_confirm);
assert.ok(S.log.includes('Emailed setup instructions to new.officer@uvu.edu'));
ok('invite new account: code in email, #code link, version echoed');
if (process.argv.includes('--show')) console.log('---- sample invite text ----\n' + m.body.text + '\n---- end ----');

// 2. invite, existing member: no password change, "now have access" + code
reset({ members: { 'new.officer@uvu.edu': { id: 'u1' } }, signedIn: { u1: true } });
r = await call({ ...base, mode: 'invite', password: '', send: true });
m = S.resendCalls[0];
assert.equal(r.j.emailed, true); assert.equal(S.users.length, 0); assert.match(m.body.text, /You now have Communications Officer access/);
assert.match(m.body.text, /setup code to choose a new password: 123456/); assert.match(m.body.text, /#code/);
// existing account that never signed in (earlier invite) gets the setup email
reset({ members: { 'new.officer@uvu.edu': { id: 'u1' } } });
r = await call({ ...base, mode: 'invite', password: '', send: true });
assert.match(S.resendCalls[0].body.text, /You have been added as Communications Officer/); assert.match(S.resendCalls[0].body.text, /Your setup code: 123456/);
// signed in before but never confirmed -> setup email
reset({ members: { 'new.officer@uvu.edu': { id: 'u1' } }, signedIn: { u1: true }, unconfirmed: { u1: true } });
r = await call({ ...base, mode: 'invite', password: '', send: true });
assert.match(S.resendCalls[0].body.text, /Your setup code: 123456/);
ok('invite existing account: no password change, sign-in email with fallback code');

// 3. generateLink fails: still emails, falls back to "Email me a code", logs it
reset({ genLinkError: 'boom' });
r = await call({ ...base, mode: 'invite', password: '', send: true });
m = S.resendCalls[0];
assert.equal(r.j.emailed, true); assert.doesNotMatch(m.body.text, /setup code/); assert.match(m.body.text, /Email me a code/);
assert.ok(S.log.some((l) => l.startsWith('Could not make a setup code')));
ok('setup-code failure falls back to the old instructions and is logged');

// 4. Resend refuses: warning text readable, logged
reset({ resendStatus: 403, resendBody: '{"statusCode":403,"name":"validation_error","message":"The wolverinefinanceassociation.org domain is not verified."}' });
r = await call({ ...base, mode: 'invite', password: '', send: true });
assert.equal(r.j.emailed, false); assert.equal(r.j.warning, 'Saved, but the email did not send: validation_error: The wolverinefinanceassociation.org domain is not verified. (HTTP 403)');
assert.ok(S.log.some((l) => l.startsWith('Email to new.officer@uvu.edu did not send: validation_error')));
ok('Resend refusal: readable warning and change-log entry');

// 5. SITE_URL with quotes and trailing slash is cleaned; missing SITE_URL falls back to https origin; bad value refuses before writes
ENV = { ...ENV_OK, SITE_URL: ' "https://wolverinefinanceassociation.org/" ' }; reset();
r = await call({ ...base, mode: 'invite', password: '', send: true });
assert.match(S.resendCalls[0].body.text, /https:\/\/wolverinefinanceassociation\.org\/#code/);
ENV = { ...ENV_OK, SITE_URL: '' }; reset();
r = await call({ ...base, mode: 'invite', password: '', send: true }, { origin: 'https://exquisite-salmiakki-d330b6.netlify.app' });
assert.match(S.resendCalls[0].body.text, /https:\/\/exquisite-salmiakki-d330b6\.netlify\.app\/#code/);
ENV = { ...ENV_OK, SITE_URL: '' }; reset();
r = await call({ ...base, mode: 'invite', password: '', send: true });
assert.equal(r.status, 500); assert.match(r.j.error, /SITE_URL/); assert.equal(S.access['new.officer@uvu.edu'], undefined); assert.equal(S.resendCalls.length, 0);
ENV = { ...ENV_OK, SITE_URL: 'https://x.org/site' }; reset();
r = await call({ ...base, mode: 'invite' }); assert.equal(r.status, 500);
ENV = { ...ENV_OK, SITE_URL: '' }; reset();
r = await call({ ...base, mode: 'manual', password: 'abcdefgh1' }); assert.equal(r.status, 200, 'manual mode needs no SITE_URL');
ok('SITE_URL cleaned, origin fallback, bad value refused before any write');

// 6. password mode on existing account confirms email
ENV = { ...ENV_OK }; reset({ members: { 'new.officer@uvu.edu': { id: 'u1' } } });
r = await call({ ...base, mode: 'password', password: 'Temp-pass9', send: true });
assert.equal(S.users[0].email_confirm, true); assert.equal(S.users[0].password, 'Temp-pass9'); assert.match(S.resendCalls[0].body.text, /Temporary password: Temp-pass9/);
ok('password mode on existing account sets email_confirm');

// 7. skip mode: no email, emailed false, mode echoed
reset(); r = await call({ ...base, mode: 'skip' });
assert.equal(r.j.emailed, false); assert.equal(S.resendCalls.length, 0); assert.equal(r.j.mode, 'skip');
ok('skip mode sends nothing');

// 8. club send: batch, one per recipient, no noreply copy, dedupe/validate
reset({ access: { 'admin@uvu.edu': 'admin', 'off@uvu.edu': 'officer' }, callerEmail: 'off@uvu.edu', profiles: { 'off@uvu.edu': { contact: 'off.contact@gmail.com' } } });
const to = Array.from({ length: 150 }, (_, i) => `m${i}@uvu.edu`).concat(['M1@UVU.EDU', 'not-an-email']);
r = await call({ action: 'send', to, subject: 'Hi', text: 'Meeting at https://wolverinefinanceassociation.org/#calendar.' });
assert.equal(r.j.sent, 150); assert.equal(r.j.failed, 0); assert.equal(S.resendCalls.length, 2);
assert.equal(S.resendCalls[0].url, 'https://api.resend.com/emails/batch'); assert.equal(S.resendCalls[0].body.length, 100); assert.equal(S.resendCalls[1].body.length, 50);
const e0 = S.resendCalls[0].body[0];
assert.deepEqual(e0.to, ['m0@uvu.edu']); assert.equal(e0.bcc, undefined); assert.equal(e0.reply_to, 'off.contact@gmail.com'); assert.equal(e0.from, ENV_OK.MAIL_FROM);
assert.ok(!JSON.stringify(S.resendCalls).includes('noreply@wolverinefinanceassociation.org"]'));
assert.match(e0.html, /<a href="https:\/\/wolverinefinanceassociation\.org\/#calendar"[^>]*>https:\/\/wolverinefinanceassociation\.org\/#calendar<\/a>\./);
ok('club send: per-recipient batches of 100, no noreply To, links clickable');

// 9. club send failure: reason returned
reset({ access: { 'admin@uvu.edu': 'admin' }, resendStatus: 429, resendBody: '{"statusCode":429,"name":"daily_quota_exceeded","message":"You have reached your daily email sending quota."}' });
r = await call({ action: 'send', to: ['a@uvu.edu'], subject: 'Hi', text: 'x' });
assert.equal(r.status, 502); assert.match(r.j.error, /daily_quota_exceeded/);
ok('club send refusal surfaces the Resend reason');

// 10. auth: expired token 401; server-side auth failure 500; non-admin invite 403; officer send allowed
reset(); r = await call({ ...base, mode: 'invite' }, { token: 'bad' }); assert.equal(r.status, 401); assert.equal(r.j.version, '2026-10-07');
reset({ getUserError: { status: 0, message: 'fetch failed' } }); r = await call({ ...base, mode: 'invite' }); assert.equal(r.status, 500); assert.match(r.j.error, /could not check your sign-in/);
reset({ callerEmail: 'off@uvu.edu', access: { 'off@uvu.edu': 'officer' } }); r = await call({ ...base, mode: 'invite' }); assert.equal(r.status, 403);
ok('auth paths: 401 / 500 / 403');

// 11. html escaping: text with <script> and quotes is escaped, URL with query string links whole
const { status: _s } = await (async () => { reset(); return call({ action: 'send', to: ['a@uvu.edu'], subject: 's', text: '<b>"hi"</b> see https://x.org/a?b=1&c=2 now' }); })();
const h = S.resendCalls[0].body[0].html;
assert.match(h, /&lt;b&gt;&quot;hi&quot;&lt;\/b&gt;/); assert.match(h, /<a href="https:\/\/x\.org\/a\?b=1&amp;c=2"/);
ok('html escaping and link with query string');

// 12. env(): quoted display name kept, whole-value quotes stripped
ENV = { ...ENV_OK, MAIL_FROM: '"Wolverine Finance Association" <noreply@wolverinefinanceassociation.org>' }; reset();
r = await call({ ...base, mode: 'invite' }); assert.equal(S.resendCalls[0].body.from, '"Wolverine Finance Association" <noreply@wolverinefinanceassociation.org>');
ENV = { ...ENV_OK, MAIL_FROM: '"Wolverine Finance Association <noreply@wolverinefinanceassociation.org>"' }; reset();
r = await call({ ...base, mode: 'invite' }); assert.equal(S.resendCalls[0].body.from, 'Wolverine Finance Association <noreply@wolverinefinanceassociation.org>');
ok('env() strips only one wrapping pair of quotes');

// 13. batch validation error falls back to one-by-one sends
ENV = { ...ENV_OK }; reset();
const realFetch = globalThis.fetch;
globalThis.fetch = async (url, init) => { const body = JSON.parse(init.body); S.resendCalls.push({ url, body });
  if (url.endsWith('/batch') || body.to[0] === 'bad@uvu..edu') return new Response('{"statusCode":422,"name":"validation_error","message":"Invalid `to` field."}', { status: 422 });
  return new Response('{"id":"x"}', { status: 200 }); };
r = await call({ action: 'send', to: ['a@uvu.edu', 'bad@uvu..edu', 'c@uvu.edu'], subject: 's', text: 't' });
globalThis.fetch = realFetch;
assert.equal(r.j.sent, 2); assert.equal(r.j.failed, 1); assert.match(r.j.reason, /^bad@uvu\.\.edu: validation_error/);
ok('batch validation error: falls back to single sends, reports the bad address');


console.log(`\nALL ${n} CHECKS PASSED`);
