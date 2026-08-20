# Privacy

Lukotta has no accounts and no analytics. The only server involved is one
holding a file that says what the latest version is.

## What leaves your Mac

One thing: a request for the update feed at
`https://lukotta-updates.rahula.dev/appcast.xml`, made daily while the app is
running.

That request carries your IP address, as any web request does, and the app and
macOS versions, which Sparkle sends so the reply can offer a suitable update.
The file is served by GitHub Pages, so those requests appear in GitHub's logs
rather than in any log of ours.

Turn it off in Settings and nothing is requested. You can still check by hand
whenever you want.

Updates are downloaded from GitHub when you choose to install one.

## What never leaves your Mac

- Your passphrase or recovery key.
- The names, contents or sizes of anything on your drives.
- Which drives you have, when you unlock them, or how often.

There is no telemetry, no crash reporting service and no analytics.

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

Storing a passphrase is optional and off unless you turn it on. It then goes to
your login Keychain, reachable only while your Mac is unlocked and marked not to
sync, so it does not travel to iCloud or another device.

Forgetting it in the app deletes the entry.

## Files on your Mac

The Linux environment is unpacked to `~/.anylinuxfs` on first use, about 95 MB.
Anything else an unlock needs is created in a private temporary folder and
removed when the app quits.

Lukotta remembers the label of a drive you have opened, so it can name it
correctly next time. A label and an identifier, nothing about the contents.

## Contact

**lukotta@rahula.dev**
