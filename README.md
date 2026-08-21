# Lukotta

**Open BitLocker and Linux drives on macOS.** Plug in the drive, type its
password, and it appears in Finder — readable and writable, like any other disk.

[lukotta.rahula.dev](https://lukotta.rahula.dev)

A native Apple Silicon app that carries everything it needs: no Homebrew, no
macFUSE, no kernel extension, and nothing downloaded on first run.

## What it opens

- **BitLocker** drives, with the password or a 48-digit recovery key
- **Windows NTFS** drives, including ones Windows left hibernated or not shut
  down properly
- **LUKS** drives from Linux, both LUKS1 and LUKS2
- **LVM inside LUKS**, as Ubuntu, Debian, Mint and Fedora set it up. Several
  volumes on one drive all unlock together
- **ext4, btrfs and XFS** filesystems inside them

It cannot open drives sealed to a TPM rather than a password, or LUKS volumes
whose header is kept away from the drive.

## Requirements

- An Apple Silicon Mac. Intel is not supported
- macOS 15 Sequoia or later
- Full Disk Access, granted once

## Installing

Download `Lukotta.app` from [Releases][releases], drag it to Applications, and
open it. It is signed and notarised, so it opens with a double-click.

### Full Disk Access

macOS refuses raw reads of a disk to every process, including ones running as
root, unless the app asking holds Full Disk Access — and an encrypted drive is
nothing but raw contents until it is unlocked. No app can request this
permission, so it has to be granted by hand. Lukotta explains it on first run
and takes you to the right place in System Settings.

## Using it

Plug in the drive and pick it from the list. Type the password or paste the
recovery key. It appears in Finder under Locations.

Eject it from Lukotta, from the menu bar, or from Finder.

Lukotta can remember a passphrase in your Keychain. It does not unless you ask
it to.

## It appears as a network drive

The drive is handed to Finder over a local network connection, so it sits under
Locations with a network icon rather than under Devices. It reads, writes and
ejects like any other drive. macOS offers no way to present it as a local disk;
[BACKGROUND.md][background] explains what was tried.

## How it works

macOS cannot read BitLocker or Linux filesystems. Linux can. So Lukotta starts a
small Linux virtual machine, unlocks the drive inside it, and hands the drive
back to Finder.

That work is done by [anylinuxfs][anylinuxfs], GPL-3, shipped inside the app.
One virtual machine per drive, 30 to 80 MB of memory each.

## Uninstalling

Dragging the app to the Bin leaves the privileged helper registered: launchd
knows about the service, not the folder it came from. To remove everything:

```bash
./scripts/uninstall.sh            # say what would go, remove nothing
./scripts/uninstall.sh --remove   # do it
```

Saved passphrases are left in your Keychain, named so you can remove them
yourself.

## Building

```bash
./scripts/fetch-engine.sh    # download the pinned engine, verify checksums
./scripts/vendor-engine.sh   # stage it into vendor/
./build-app.sh               # compile, embed, sign, install
```

The whole path, including how to reproduce a released build, is in
[BUILDING.md][building]. To work on Lukotta, see [CONTRIBUTING.md][contributing].

## Privacy and security

Nothing is collected. The only request Lukotta makes on its own is a daily check
for updates, which can be turned off — [PRIVACY.md][privacy] says exactly what
that involves.

Your passphrase never touches the disk in the clear and never appears in a
command line. [SECURITY.md][security] describes how it is handled, what the
privileged helper will and will not accept, and where to report a fault.

## Licence

GPL-3.0-or-later. Complete source for every component, including the GPL parts
inside the app, is published with each release.

The name Lukotta and the logo are trademarks and are not covered by that
licence, as GPL-3 section 7(e) allows. Fork the code freely; give your version
its own name. [TRADEMARKS.md][trademark] says what that means in practice.

[Licence][licence] · [Trademarks][trademark] · [Third-party notices][notices] · [Changelog][changelog]

## Author

Clement Rahula — [lukotta@rahula.dev](mailto:lukotta@rahula.dev) ·
[rahula.dev](https://rahula.dev)

Built on [anylinuxfs][anylinuxfs] by nohajc, which does the mounting, and on
[Sparkle][sparkle] for updates. Lukotta is not affiliated with Microsoft, Apple,
or the Linux projects it works with.

[releases]: https://github.com/clementrahula/lukotta/releases
[background]: BACKGROUND.md
[building]: BUILDING.md
[contributing]: CONTRIBUTING.md
[privacy]: PRIVACY.md
[security]: SECURITY.md
[licence]: LICENSE.txt
[trademark]: TRADEMARKS.md
[notices]: THIRD_PARTY_NOTICES.md
[changelog]: CHANGELOG.md
[anylinuxfs]: https://github.com/nohajc/anylinuxfs
[sparkle]: https://sparkle-project.org
