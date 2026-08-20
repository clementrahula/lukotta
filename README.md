# Lukotta

Open BitLocker-encrypted drives on macOS. Unlock with the drive's password or
its 48-digit recovery key, and it mounts read/write in Finder.

Native Apple Silicon app. No Homebrew, no macFUSE, no kernel extension, no
system extension, and nothing downloaded on first run — the entire engine ships
inside the app.

## Requirements

- Apple Silicon Mac (arm64)
- macOS 15 Sequoia or later
- Full Disk Access granted to Lukotta (one-time, see below)

## Install

Download `Lukotta.app`, drag it to **Applications**, and open it.

The app is signed with a Developer ID certificate. It is not notarised yet, so
the first launch may need **right-click → Open** rather than a double-click.

### One-time: Full Disk Access

macOS refuses raw reads of an encrypted disk to *every* process — including ones
running as root — unless the responsible app holds Full Disk Access. An
administrator password is not sufficient on its own.

1. **System Settings → Privacy & Security → Full Disk Access**
2. Click **+**, press **⌘⇧A**, and pick **Lukotta**
3. Switch it on, then quit and reopen Lukotta

The app detects when macOS has refused access and walks you through this, rather
than failing with a cryptic error.

## Using it

1. Open Lukotta. Connected BitLocker-candidate drives are listed.
2. Pick the drive, enter its password or recovery key, click **Unlock**.
3. Approve the single administrator prompt.
4. The drive appears in Finder, readable and writable.
5. **Eject** in the app or in Finder when done. Ejecting needs no password.

Recovery keys may be typed with hyphens, spaces, or as one 48-digit run. The
app validates the checksum before anything is attempted, so a mistyped key is
reported precisely instead of as a generic unlock failure.

## Known limitation: it mounts as a network drive

The drive appears in Finder under **Locations**, but macOS classifies it as a
network volume rather than a local disk.

This is architectural. The engine reads the drive inside a Linux microVM and
re-exports it to `127.0.0.1` over NFS — upstream states that "by design, any
mounted volume is seen by macOS as a network drive shared by our virtual
machine". macOS offers no supported way to mark an NFS mount local: there is no
`local` option in `mount_nfs`, and `MNT_LOCAL` is not settable from user space.

Everything works — read, write, eject — but Finder shows a network volume, and
in-place renaming is not offered for network volumes. See
[PRODUCTION-READINESS.md](PRODUCTION-READINESS.md) §7 for the routes out of this
(FSKit, DriverKit) and why neither is available today.

## How it works

```
Lukotta.app  ──►  anylinuxfs  ──►  Linux microVM (libkrun)
   SwiftUI          embedded          cryptsetup unlocks BitLocker
   one auth         engine            ntfs3 mounts the volume
   prompt                             NFS server exports it
                                             │
   Finder  ◄────────  /Volumes/<label>  ◄─────┘  localhost NFS
```

The credential is passed to the elevated process through a FIFO, so it never
appears in an argument list, an exported environment, or on disk.

## Building

```bash
./vendor-engine.sh     # stage the engine + Linux image into vendor/
./build-app.sh         # compile, embed, sign, install to /Applications
./tests/run-all.sh     # shell + Swift unit tests
```

`vendor-engine.sh` currently stages from an anylinuxfs runtime already present
on the build machine. Reproducible builds from pinned upstream artefacts are
still outstanding — see PRODUCTION-READINESS.md §6.

Outstanding work is tracked in [TODO.md](TODO.md).

Versioning is semver in `VERSION`; the build number is the git commit count.

```bash
./scripts/bump-version.sh patch   # or minor / major, commits and tags
```

## Licence

**GPL-3.0-or-later.** Lukotta embeds anylinuxfs (GPL-3.0-or-later), a Linux
kernel image (GPL-2.0-only) and an Alpine Linux userland, so the combined work
is distributed under the GPL. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), which is generated from the
components actually shipped and carries the written offer for source.

This also means Lukotta cannot be published on the Mac App Store — both because
of the licence and because App Store apps must be sandboxed, which rules out raw
disk access and privilege elevation.

## Acknowledgements

Built on [anylinuxfs](https://github.com/nohajc/anylinuxfs) by nohajc, which
does the hard part.
