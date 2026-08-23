# Security Policy

Lukotta reads raw disks, parses disk images it is given, handles disk
encryption passphrases, and runs part of itself as root. This document states
how each of those is done, and where to report a fault.

## Reporting a Vulnerability

Email **lukotta@rahula.dev**. Please do not open a public issue for anything
that could expose someone's passphrase or their data.

Include what you did, what happened, the version from the Help screen, and
whether the background helper was installed. If a report needs a log, use the
bug icon in the app: it removes the passphrase from the engine output and shows
you the whole report before anything is sent.

One person maintains this, so there is no response window and no bounty.
A reply usually follows within a few days.

## In Scope

- Anything that exposes a passphrase or recovery key: in a log, a report, a
  crash file, on disk, or in the interface.
- Anything that lets a process other than Lukotta ask the privileged helper to
  do something.
- Anything that changes a drive's contents during an unlock intended only to
  read it.
- Anything that makes the app accept an update it should have refused.
- A disk image that causes a file it did not receive to be opened: one naming
  a backing file, an extent or a parent disk.
- A disk image that makes a format driver read outside the file, allocate
  without bound, or serve one part of the file as another.

## Out of Scope

- Vulnerabilities in anylinuxfs, libkrun or the Linux packages inside the
  guest image. Report those upstream; tell me as well if Lukotta ships an
  affected version. The format drivers for VDI, VHD, VHDX and VMDK are written
  here and are in scope above.
- macOS asking for Full Disk Access, or the system's own dialogs.
- Anything requiring an attacker who is already root on the machine.

## Your Passphrase

It is never written to disk in the clear, and never appears in a command line.

Unlocking needs the passphrase to reach a program running as root. It is
written to a named pipe in a private directory, read once from there, and
handed to the engine as an environment variable of that root-owned process. It
is not an argument, so it does not appear in `ps`; the environment of a root
process can only be read by root.

The engine is driven through a pseudo-terminal, which echoes what is written
to it, so the passphrase can appear in the engine's own output. Transcripts are
therefore filtered by value: the exact string is removed before anything reaches
the screen, a log or a bug report. Matching on shape would catch a recovery key
and miss an ordinary passphrase.

Storing it is optional and off by default. If you turn it on, it goes to the
login Keychain, reachable only while the Mac is unlocked, and never synced to
iCloud or another device. Forgetting it deletes the entry.

## The Privileged Helper

Unlocking a drive requires root. Without the helper, macOS asks for an
administrator password each time. With it, a small daemon holds that privilege
so the password is asked for once, when it is installed.

The daemon accepts parameters, never a command, so it cannot be used to run
arbitrary code as root. It is given a device path, a volume name and a
passphrase, and composes the command itself.

Whom it is mounting for comes from the connection: the application runs as the
person whose drive is being opened, and the connection says who that is. Where
that cannot be established the mount is refused rather than directed at a
guess, so a second account on the Mac cannot be handed a mount composed against
somebody else's home directory.

Every connection is checked against a code requirement pinning both the
application's identifier and the signing team. Anything that is not Lukotta,
or is signed by anyone else, is refused.

The helper can be removed at any time from Login Items in System Settings.
Lukotta falls back to asking for an administrator password.

## Disk Images

An image is opened without any privilege. The helper is not involved, no device
is attached for the formats the engine reads itself, and the volume is mounted
under the user's own home folder. What an image can reach is therefore bounded
by what the person who opened it could already read.

That bound is not relied on alone. Every format other than raw can name another
file, and libkrun opens whatever an image names, so an image could otherwise
determine which files the virtual machine reads. Each such image is refused
before the engine is given the path: a qcow2 with a backing or external data
file, a VMDK snapshot chain, a differencing VHD, and a VHDX naming a parent.
A VMDK's extents must each be a plain name beside the descriptor — nothing
absolute, nothing with a separator in it, no `..` — and the file that name
resolves to must still be in that folder, so a link out of it is refused as a
path out of it would be. An extent naming no file at all is refused too, since
it describes part of a disk that is nowhere. The drivers refuse all of this as
well, so the rule holds in both layers.

The drivers parse a file supplied by whoever opened it, and validate every
value before relying on it: block sizes must be powers of two, maps are bounded
to a size a real disk could require, and every entry must lie within the file.
[SPECS.md](SPECS.md) states what each format is and which images are refused.

Reading is not all they do. qcow2, VDI, VHD and VMDK are written as well, so a
driver handed a hostile image also allocates in response to it — growing the
file, and writing a table entry that points at the new space. The same
validation governs that path, and the order is fixed so an interrupted write
leaves unused space rather than a table pointing at nothing. VHDX and the
stream-optimized form of VMDK are never written.

A file that will not open for writing — an image on a read-only volume, a
locked file, a card with its switch set — is opened for reading instead, and
the guest is told the device is read-only. Refusing outright would leave no way
in at all, when reading was possible throughout.

## What the App Can Reach

Full Disk Access is required to read a drive. macOS blocks reading a drive's
raw contents without it, and an encrypted drive is nothing but raw contents
until it is unlocked. No app can request it; it has to be granted by hand. A
disk image is an ordinary file and requires none of this.

The engine is inside the app, so no component is downloaded at first run. The
only outbound request Lukotta makes on its own is the update check, described in
[PRIVACY.md](PRIVACY.md).

## Updates

An update is verified twice before it is installed: by an EdDSA signature over
the archive, made with a key held only by the author, and by macOS against the
Developer ID signature of the app inside it. A build that fails either is
refused.

If an update installs and then will not start, the previous version is put
back after two failed starts.

## What This Does Not Protect Against

- A Mac that is already compromised. A process running as root can read the
  environment of another root process, and can talk to anything.
- Someone who has your passphrase, or a Mac left unlocked with a drive open.
- A drive that was already tampered with. Lukotta unlocks what it is given and
  cannot tell you whether the contents were altered before you plugged it in.
  The same holds for a disk image: the checks above stop an image reaching other
  files, and say nothing about whether its contents are what you expect.
- The initialise dialog when Lukotta is not running. Lukotta suppresses it by
  claiming drives it recognises, and a claim belongs to a running process.