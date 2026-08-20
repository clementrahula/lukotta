# Privacy

Lukotta has no accounts, no analytics, and no server that belongs to it beyond a
file listing the latest version.

## What leaves your Mac

One thing: a request for the update feed at
`https://lukotta-updates.rahula.dev/appcast.xml`, made daily while the app is
running.

Like any web request, it tells the server the address it came from, along with
the app version and macOS version that Sparkle includes so it can offer a
suitable update. The file is served by GitHub Pages, which keeps its own logs;
that data is GitHub's, not ours, and nothing about it identifies you beyond what
any visit to any website reveals.

Turn it off in Settings and nothing is requested at all. Lukotta will not check
for updates, and you can still check by hand whenever you want.

Updates are downloaded from GitHub when you choose to install one.

## What never leaves your Mac

- Your passphrase or recovery key.
- The names, contents or sizes of anything on your drives.
- Which drives you have, when you unlock them, or how often.

There is no telemetry, no crash reporting service, and no analytics of any kind.

## Bug reports

The bug icon in the app gathers the app version and build, the macOS version,
the model of Mac, whether the engine is present, whether Full Disk Access is
granted, and the last 4,000 characters of the engine's output.

If macOS has written a crash report for this exact build in the past day, the
report names its file. The contents of that file are not included and are not
read — attaching it, if you want to, is something you do yourself.

Nothing is sent automatically. The whole report is shown to you first, and
copying it or opening an email is your decision. If you send one, it goes to a
person's inbox, not a system.

The passphrase is removed from that output by value before you see it: the exact
string is deleted, not merely anything shaped like a key.

## Passphrases you asked to be remembered

Storing a passphrase is optional and off unless you turn it on. When you do, it
goes to your login Keychain, reachable only while your Mac is unlocked, and it
is marked not to sync — it will not travel to iCloud or another device.

Forgetting it in the app deletes the entry.

## Files on your Mac

The Linux environment is unpacked to `~/.anylinuxfs` on first use, about 95 MB.
Everything an unlock needs beyond that is created in a private temporary folder
and removed when the app quits.

Lukotta keeps the label of a drive you have opened, so it can name the drive
correctly next time. That is a name and an identifier, nothing about contents.

## Contact

**lukotta@rahula.dev**
