# Privacy Policy

Applies to: Lukotta 1.x
Website: lukotta.rahula.dev
Effective: 21 August 2026

Lukotta is written and published by Clement Rahula, an individual residing in
the Republic of Estonia (the "Developer").

For privacy questions or requests, contact **lukotta@rahula.dev**.

## Plain-English Summary

Lukotta has no accounts, no analytics and no telemetry. It never sees what is
on your drives, and your passphrase never leaves your Mac.

The app makes one network request on its own: a daily check for a newer
version. That can be turned off in Settings, after which it makes none.

The Developer receives personal data only when you choose to send it — by
email, or through the bug reporter, which shows you the whole report first and
sends nothing by itself.

## The App

Lukotta unlocks drives on your Mac. Nothing about a drive is transmitted: not
its contents, not the names or sizes of files on it, not which drives you
have, not when you unlock them or how often.

Your passphrase is never written to disk in the clear and never appears in a
command line. [SECURITY.md](SECURITY.md) describes how it is handled.

### Checking for Updates

While the app is running, it asks `lukotta-updates.rahula.dev` once a day
whether a newer version exists. That request carries your IP address, as any
web request does, along with the app version and the macOS version, which
Sparkle sends so the reply can offer a suitable update.

The legal basis for this processing is the Developer's legitimate interest in
delivering security and reliability fixes to installed copies.

Turn it off in **Settings → Updates** and the app makes no requests at all.
You can still check by hand whenever you want. Updates themselves are
downloaded from GitHub only when you choose to install one.

## Bug Reports and Email

The bug icon in the app gathers the app version and build, the macOS version,
the model of Mac, whether the engine is present, whether Full Disk Access is
granted, and the last 4,000 characters of the engine's output. If macOS has
written a crash report for that exact build in the past day, the report names
the file; its contents are neither read nor included.

Your passphrase is removed from that output by value — the exact string is
deleted, not merely anything shaped like a key.

Nothing is sent automatically. The whole report is shown to you first, and
copying it or opening an email is your decision.

If you email the Developer, for a bug or anything else, that email arrives
with what you chose to send: your address, your message, and any attachment.
This is used to reply, to investigate problems, and to maintain Lukotta. The
legal basis is the Developer's legitimate interest in supporting the software.

## The Website and the Update Feed

The website at `lukotta.rahula.dev` is hosted on GitHub Pages and delivered
through Cloudflare. The update feed at `lukotta-updates.rahula.dev` is served
by GitHub Pages directly, without Cloudflare.

Neither uses cookies, advertising trackers, visitor profiling or analytics.

## Passphrases You Ask to Be Remembered

Storing a passphrase is off unless you turn it on. It then goes to your login
Keychain, reachable only while your Mac is unlocked and marked not to sync, so
it does not travel to iCloud or another device. It stays on your Mac and is
never transmitted. Forgetting it in the app deletes the entry.

## Files on Your Mac

The Linux environment is unpacked to `~/.anylinuxfs` on first use, about 95
MB. Anything else an unlock needs is created in a private temporary folder and
removed when the app quits.

Lukotta remembers the label of a drive you have opened, so it can name it
correctly next time. A label and an identifier, nothing about the contents.

## Service Providers

- **GitHub** hosts the website, the update feed, the source repository and the
  downloads. Requests to any of them appear in GitHub's logs.
  <https://docs.github.com/site-policy/privacy-policies/github-privacy-statement>
- **Cloudflare** delivers and protects `lukotta.rahula.dev`.
  <https://www.cloudflare.com/privacypolicy/>

The app does not connect to Cloudflare, and neither provider receives anything
about your drives.

## How Long Data Is Kept

There are no accounts, no telemetry and no analytics, so the Developer keeps
no database of users or drives.

Email you send is normally kept for up to two years after the last exchange.
It may be kept longer where needed to resolve an ongoing matter, to comply
with a legal obligation, or to establish, exercise or defend a legal claim.

Server logs are kept by GitHub and Cloudflare under their own retention
policies, linked above. The Developer does not receive or store them.

## Your Rights

Where the GDPR applies, you may have rights over personal data processed about
you: access, correction, deletion, restriction, objection and portability. To
exercise them, contact **lukotta@rahula.dev**.

Because so little is collected, the Developer will usually hold nothing that
identifies you, and may be unable to link a request to any stored data. You
may also complain to your local data protection authority; in Estonia that is
the Andmekaitse Inspektsioon.

## Changes to This Policy

This policy may change as Lukotta changes. The effective date at the top is
updated when it does, and previous versions are visible in the repository's
history.
