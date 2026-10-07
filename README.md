# Wolverine Finance Association website

- `site/` is the website Netlify publishes.
- `supabase/` holds the database setup, the invite-officer function, and the email templates. These are pasted into Supabase by hand and are not part of the public site.

## Email setup (done in the dashboards, not by pushing to GitHub)

Pushing to `main` updates the website only. The invite-officer function and the Supabase settings change only when someone pastes or sets them by hand. Do the steps in this order.

1. **Website first.** Merge to `main` and wait for Netlify. Check that `https://wolverinefinanceassociation.org/#code` shows "Set up your account". Officer setup emails from the new function link there.
2. **Codes, not links.** Supabase > Authentication > Emails > Templates:
   - Confirm signup: paste `supabase/12-confirm-signup-template.html`. It sends a code only. University email scanners open links before people do, which can confirm an account for someone who doesn't own the address. A code can't be used that way.
   - Reset password: paste `supabase/3-reset-email-template.html`.
3. **Code settings.** Supabase > Authentication > Providers > Email (or Sign In / Providers > Email): Email OTP length `10`; Email OTP expiration `86400` (24 hours, so a setup code is still good the next day). Keep the length at 10 if the expiration is long: a 6-digit code can be guessed within a day.
4. **Custom SMTP.** Supabase > Authentication > Emails > SMTP Settings: host `smtp.resend.com`, port `465`, user `resend`, password = a Resend API key, sender `noreply@wolverinefinanceassociation.org`, name `Wolverine Finance Association`. Without it, Supabase only emails people on the Supabase project team, so member sign-up codes and "Email me a code" never reach @uvu.edu addresses. Then raise Authentication > Rate Limits > emails per hour (30 by default).
5. **Links.** Supabase > Authentication > URL Configuration: Site URL `https://wolverinefinanceassociation.org`; Redirect URLs `https://wolverinefinanceassociation.org/**` and `https://exquisite-salmiakki-d330b6.netlify.app/**`.
6. **Function secrets.** Supabase > Edge Functions > Secrets: `RESEND_API_KEY`; `MAIL_FROM` = `Wolverine Finance Association <noreply@wolverinefinanceassociation.org>`; `SITE_URL` = `https://wolverinefinanceassociation.org` (no quotes, no trailing slash).
7. **Function code last.** Supabase > Edge Functions > invite-officer > Code: paste all of `supabase/2-invite-officer.ts` and deploy. Its `VERSION` must match `FUNCTION_VERSION` in `site/index.html`. After you add an officer, the site warns if they differ.
8. **Check.** Resend > Domains shows `wolverinefinanceassociation.org` as Verified. Add a test officer, or use Change role on your own row with the first Sign-in setup option. The email should have a setup code that works on `#code`.

If UVU's network blocks the club domain (it did for its first hours after registration on 2026-10-06), set the `SITE_URL` secret and `PUBLIC_URL` in `site/index.html` to `https://exquisite-salmiakki-d330b6.netlify.app` until UVU IT allows the domain.
