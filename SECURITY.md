# Security

Lukotta reads raw disks, handles disk encryption passphrases, and runs part of
itself as root. This describes how it does those things and how to report it
when something is wrong.

## Reporting a vulnerability

Email **lukotta@rahula.dev**. Please do not open a public issue for anything
that could expose someone's passphrase or their data.

Useful things to include: what you did, what happened, the version from the
Help screen, and whether the background helper was installed. If a report needs
a log, use the bug icon in the app — it scrubs the passphrase out of the engine
output and shows you the whole report before anything is sent.

Expect an acknowledgement within a few days. This is a one-person project, so
there is no formal response window, and no bounty.

## In scope

- Anything that exposes a passphrase or recovery key: in a log, a report, a
  crash file, on disk, or in the interface.
- Anything that lets a process other than Lukotta ask the privileged helper to
  do something.
- Anything that lets a drive's contents change during an unlock that was only
  meant to read it.
- Anything that makes the app accept an update it should have refused.

## Out of scope

- Vulnerabilities in anylinuxfs, libkrun or the Linux packages inside the guest
  image. Report those upstream; tell us too if Lukotta ships an affected
  version.
- macOS asking for Full Disk Access, or the system's own dialogs.
- Anything requiring an attacker who is already root on the machine.

## Your passphrase

It is never written to disk in the clear, and never appears in a command line.

Unlocking needs the passphrase to reach a program running as root. It is written
to a named pipe in a private directory, read once from there, and handed to the
engine as an environment variable of that root-owned process. It is not an
argument, so it does not appear in `ps`; the environment of a root process can
only be read by root.

The engine is driven through a pseudo-terminal, and a pseudo-terminal echoes
what is written to it, so the passphrase can come back inside the engine's own
output. Because of that, transcripts are scrubbed by value — the exact string is
removed — before they reach the screen, a log, or a bug report. Pattern matching
alone would not catch an ordinary passphrase.

Storing it is optional and off by default. When chosen, it goes to the login
Keychain, reachable only while the Mac is unlocked, and never synced to iCloud
or another device. Forgetting it deletes the entry.

## The privileged helper

Unlocking a drive requires root. Without the helper, macOS asks for an
administrator password each time. With it, a small daemon holds that privilege
so the password is asked for once, when it is installed.

The daemon accepts parameters, never a command. It is given a device path, a
volume name and a passphrase, and composes the command itself from the same
builder the app uses, so a caller cannot use it to run arbitrary code as root.

Every connection is checked against a code requirement pinning both the
application's identifier and the signing team. A binary that is not Lukotta,
signed by anyone else, is refused.

It can be removed at any time from Login Items in System Settings. Lukotta falls
back to asking for an administrator password.

## What the app can reach

Full Disk Access is required, because macOS blocks reading a drive's raw
contents without it — and an encrypted drive is only raw contents until it is
unlocked. It cannot be requested by an app; it has to be granted by hand.

Nothing is sent anywhere. The engine is inside the app, so no component is
downloaded at first run. The only outbound request Lukotta makes on its own is
the update check, described in [PRIVACY.md](PRIVACY.md).

## Updates

An update is verified twice before it is installed: by an EdDSA signature over
the archive, made with a key held only by the author, and by macOS against the
Developer ID signature of the app inside it. A build that fails either is
refused.

If an update installs and then will not start, the previous version is put back
after two failed launches.

## What this does not protect against

- A Mac that is already compromised. A process running as root can read the
  environment of another root process, and can talk to anything.
- Someone who has your passphrase, or a Mac left unlocked with a drive open.
- A drive that was already tampered with. Lukotta unlocks what it is given; it
  cannot tell you whether the contents were altered before you plugged it in.
- The initialise dialog when Lukotta is not running. Lukotta suppresses it by
  claiming drives it recognises, and a claim belongs to a running process.
