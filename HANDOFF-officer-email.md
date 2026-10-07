# Handoff: officer invite emails (PR #1)

**For:** Paula's Claude (Claude Code), working with Paula.
**From:** Dave Coltrin's Claude, 2026-10-07.
**PR:** https://github.com/Paula-Gaona/wfa-site/pull/1 (branch `fix/officer-invite-email-uvu`)

## Your job

Get PR #1 live and prove it with one test email to `11067393@uvu.edu` (Dave's UVU mailbox).

Two parts of this repo deploy differently. Pushing to `main` publishes only `site/` (through Netlify). Everything in `supabase/` changes only when someone pastes it into the Supabase dashboard. So the PR fixes nothing until both parts are done, **in the order below**.

### How to work with Paula

Paula is not technical. **Do everything you can yourself** and keep what you ask of her to decisions, approvals, and typing secrets.

- **Do it yourself:** git, reading the diff, running the tests, merging main into the branch if needed, checking the live site, reading logs, and anything in the Supabase or Resend dashboards your tools can reach while she is signed in. That includes a browser tool or the Supabase CLI/MCP, if you have them.
- **Ask before** anything that changes production: merging, changing a Supabase setting, deploying the function, or sending an email. Say in one sentence what it does, then ask.
- **When she has to click:** give one step at a time, in plain words. Name the exact button and say what she should see afterwards. Wait for her to confirm before giving the next step. No jargon. Say "the settings page for sign-in emails", not "auth config".
- **Secrets:** she pastes API keys into the dashboard herself. Never ask for one in chat, never commit one.
- **When you're done:** give her a short plain-English summary of what changed, what's left, and who to tell.

### Step 0a: check what's new before anything else

Main may have moved since this was written (base `0b57c32`), and the deployed function may differ from the repo.
- Run `git fetch` and compare `main` with this branch. If `main` has new commits, merge `main` into the branch, resolve any conflicts, re-run `node supabase/test/invite-officer.test.mjs`, and push.
- Read the whole PR diff and check it against the claims in this file. If anything here looks wrong or out of date, trust what you verify, and tell Paula what was different.
- Give Paula a plain-English summary of what the PR changes, about five bullet points, before asking to merge.

## The problem (reported 2026-10-06)

1. Emails don't go out after someone is added to the officer/admin list.
2. On phones the email notification arrives, but tapping through doesn't work.
3. Recipients are @uvu.edu, which is Microsoft 365.

| Cause | Checked? | What the PR does |
|---|---|---|
| The "setup link" invite told officers to click "Forgot your password?". That code comes from Supabase's built-in mailer, which only emails the Supabase project team, so @uvu.edu never gets it. | Mechanism from code and Supabase docs. Whether the project uses the built-in mailer is **not verified**. | Puts the setup code in the invite email (`generateLink` → `email_otp`). A new `#code` page opens straight to code entry. |
| `invite-officer` is pasted by hand. Copies older than 7687513 send nothing in the default mode, and the site still said "Saved". | Deployed version **not verified** | The site now shows a warning that stays on screen when no email or no code went out. The function returns `version`. |
| Promoting an existing member defaulted to "don't email" | From code | Now defaults to emailing them |
| UVU's firewall blocked wolverinefinanceassociation.org, which was registered 2026-10-06 20:13 UTC | Blocked at 03:20 UTC on 10-07, loading by 03:58 UTC, tested from UVU Wi-Fi | Nothing needed. If it comes back, see "If something fails". |
| Club emails went To: noreply@ (no MX record) with members in BCC | From DNS and code | One copy per person through Resend `/emails/batch` |
| UVU's link scanner can open a confirmation link, which would confirm an account for someone who doesn't own the address | From code and GoTrue source | Sign-up accepts a code; there is a new code-only confirm template |

## Steps, in order

**0. Read-only check first (no changes, about 10 minutes).** Report the results to Paula before doing anything else:

| Check | Where | What it tells you |
|---|---|---|
| Does the deployed code contain `const MODES` and `const VERSION`? | Supabase > Edge Functions > invite-officer > Code | No MODES means older than 7687513: the cause of "no email". No VERSION means this PR isn't deployed yet. |
| Built-in mailer or custom SMTP? | Supabase > Authentication > Emails > SMTP Settings | Built-in means member sign-ups and reset codes can't reach @uvu.edu today |
| Is `wolverinefinanceassociation.org` Verified? Any bounces or failures for @uvu.edu? | Resend > Domains; Resend > Emails | Whether Resend is sending at all |
| Errors from invite-officer in the last 48 hours | Supabase > Edge Functions > invite-officer > Logs/Invocations | The real error text |
| "Gave X access" rows with no matching "Emailed setup instructions to X" | Site > Admin > Change log | Who never got an email |

**1. Review and test the PR.** Read the diff. Run the offline function tests from the repo root:

```bash
node supabase/test/invite-officer.test.mjs
```

You should see 13 checks pass. This needs Node 22.18 or newer, and nothing is sent. The site has no automated tests. It was smoke-tested in a browser with a fake Supabase client: `#code`, the sign-up code step, the warnings, the bulk guards, and the busy lock.

**2. Merge.** Ask Paula, then merge it yourself (`gh pr merge 1 --merge`). Netlify publishes `site/` within a few minutes. Then check that `https://wolverinefinanceassociation.org/#code` shows "Set up your account". It is safe to merge before the function is pasted: with the old function, the site warns that the email had no setup code.

**3–6. Dashboard settings.** If your tools can reach the dashboard, make the changes yourself with her OK. Otherwise walk her through one click at a time. These are README steps 2–6:
- Templates: Confirm signup ← `supabase/12-confirm-signup-template.html`; Reset password ← `supabase/3-reset-email-template.html`
- Email OTP length `10`, expiration `86400`. Keep 10 digits if the expiration is long, or the code can be guessed.
- Custom SMTP through Resend (`smtp.resend.com`, port 465, user `resend`, a Resend API key that Paula creates and pastes herself), then raise the email rate limit
- URL configuration: Site URL `https://wolverinefinanceassociation.org`; Redirect URLs for the apex and `https://exquisite-salmiakki-d330b6.netlify.app`
- Edge Function secrets: `RESEND_API_KEY`, `MAIL_FROM`, `SITE_URL` (`https://wolverinefinanceassociation.org`, no quotes, no trailing slash)

If Paula has the Supabase CLI or MCP linked to project `razxymbbfsnnnguyaalp`, you may set the auth settings through the Management API. Check the field names against the current docs first; the dashboard is the safe default.

**7. Deploy the function.** Do it yourself if you can (CLI or browser); otherwise walk her through it. Paste all of `supabase/2-invite-officer.ts` into Edge Functions > invite-officer > Code and deploy. The file is plain ASCII on purpose, so don't let an editor turn quotes curly. If you deploy with the CLI instead, the function name is `invite-officer`, and **leave the "Verify JWT" setting as the dashboard shows it now**.

**8. Test email.** Paula has to be signed in to the site as an admin, so do it in her browser or walk her through it. On the site: Admin > Access lists. If `11067393@uvu.edu` is listed, use **Change role** on that row, keep its access level, choose the first Sign-in setup option, and Save. If it is not listed, ask Dave before adding him. Expect "Saved. Setup email sent to 11067393@uvu.edu" and **no** warning modal. Then tell Dave it has been sent. His Claude can read that mailbox and will check the folder (Inbox, not Junk or quarantine), the `Authentication-Results` header (spf, dkim and dmarc all pass), and that the code works on `#code`.

**9. Re-send to people who never got a usable invite.** Ask Paula first, because this emails people. For each officer marked "no account yet", or who never finished setup: Change role → first Sign-in setup option → Save. Use Change role, **not** the Add form or bulk import.

## Don't

- Don't paste the function before the site is merged (step 2). The new emails link to `#code`, which only exists after the merge.
- Don't switch email links to the netlify.app address unless a phone on UVU Wi-Fi (cellular off) can't open `https://wolverinefinanceassociation.org/#code`.
- Don't go back to link-based confirm or reset emails. University scanners use up the links, and they can let someone claim an address.
- Don't edit `2-invite-officer.ts` without changing `VERSION` there and `FUNCTION_VERSION` in `site/index.html` together, then re-running the tests.

## Decisions already made (don't reopen)

- Setup codes go in the Resend email. Supabase's mailer is only the fallback ("Email me a new code").
- Email links use the club domain (`SITE_URL`, and `PUBLIC_URL` in `site/index.html`).
- Club emails are one copy per recipient. If Resend rejects a batch on validation, the function sends that batch one by one.
- Promotions email by default. Editing someone who is already staff defaults to no email.
- No Netlify ignore rule. It was tried and removed because it cancelled empty "republish" commits.

## Open items not in the PR

| Item | Why it's left |
|---|---|
| Any officer can send a club email to any address list | Existed before the PR and wasn't part of the report; Paula's call |
| Resend free plan allows 100 emails a day, shared by invites, codes and club sends | A cost decision. Pro is $20/month. |
| Officer and admin login emails are visible to anyone through `officers_public` | Existed before the PR; a design call |

## If something fails

| Symptom | Likely cause | Look at |
|---|---|---|
| Modal: "No email went to X", with no Resend text | Function is still an older copy | Step 7 |
| Modal: "The email to X had no setup code" | Function is older than this PR | Step 7 |
| Modal with "validation_error ... domain is not verified" | Resend domain isn't verified | Resend > Domains |
| `daily_quota_exceeded` | Resend's 100-a-day free cap | Wait until 00:00 UTC, or upgrade |
| "The site can't email that address yet" | Supabase is still on its built-in mailer | Step 4 (custom SMTP) |
| "Server setup problem: the SITE_URL secret..." | Bad secret value | Step 6 |
| Test email is in Junk or quarantine | New domain's reputation at Microsoft | Ask UVU IT (itsecurity@uvu.edu) for a message trace and an allow entry for the sending domain |
| Link won't open on campus Wi-Fi | UVU URL filter is back | Ask UVU IT to allow the domain; meanwhile switch `SITE_URL` and `PUBLIC_URL` to the netlify.app address |

Delete this file after the handoff is finished.
