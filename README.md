<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/brand/lukotta-logo-dark.webp">
    <source media="(prefers-color-scheme: light)" srcset="assets/brand/lukotta-logo-light.webp">
    <img src="assets/brand/lukotta-logo-light.webp" alt="Lukotta" width="320">
  </picture>
</p>

<p align="center">
  <strong>Open BitLocker, Linux and virtual machine disks on macOS.</strong><br>
  Plug in a drive or open a disk image, type the password, and it appears in
  Finder, readable and writable, like any other disk.
</p>

<p align="center">
  <img src="https://img.shields.io/github/v/release/clementrahula/lukotta?label=version&color=111111" alt="Latest released version">
  <img src="https://img.shields.io/badge/macOS-15%20Sequoia%2B-111111" alt="macOS 15 Sequoia or later">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-111111" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/licence-GPL--3.0--or--later-3b6ea5" alt="GPL-3.0-or-later">
</p>

<p align="center">
  <a href="https://lukotta.com">lukotta.com</a> ·
  <a href="https://github.com/clementrahula/lukotta/releases">All releases</a>
</p>

<p align="center">
  <a href="https://github.com/clementrahula/lukotta/releases/latest/download/Lukotta.dmg">
    <img src="https://img.shields.io/badge/Download-Lukotta%20for%20macOS-3b6ea5?style=for-the-badge"
      alt="Download Lukotta for macOS">
  </a>
</p>

Or with [Homebrew](https://brew.sh):

Release:

```bash
brew install --cask clementrahula/tap/lukotta
```

Pre-release (Beta):

```bash
brew install --cask clementrahula/tap/lukotta@beta
```

<p align="center">
  <img src="assets/screenshots/en-light-readme.png" width="400"
    alt="The drive list in the light appearance: a BitLocker drive, two LUKS disk images and a VirtualBox disk open, and a second BitLocker drive still locked.">
  <img src="assets/screenshots/en-dark-readme.png" width="400"
    alt="The same drive list in the dark appearance.">
</p>

## About

I wanted backups from a Windows PC and a Mac on the same external disk. The Mac
could not open the BitLocker volume, and the existing ways of doing it were
more complicated than they needed to be.

macOS cannot mount BitLocker volumes, Linux filesystems such as ext4, btrfs and
XFS, LUKS encryption, or most virtual machine disk images. Linux can, and the
tools for that already exist.

Lukotta is built on anylinuxfs, which opens the drive inside a small Linux
virtual machine and hands it back to macOS. anylinuxfs is a command-line tool,
which rules it out for most people. There are graphical wrappers for tools like
it, but they look and feel like an aeroplane cockpit.

Lukotta's main goal is perfect user experience: plug in the drive, type the
password, open it in Finder. A drive should be fully usable on any computer.

> [!WARNING]
> **Early development.** Lukotta is still new. The Linux tools and drivers it
> relies on have been around for years and are well tested. Lukotta is built on
> top of them, but it is still in development, so there inevitable are issues yet
> to be uncovered. For now, using it for opening drives and images in read-only
> mode is the safest thing to do. Writing does work, but please treat it as
> experimental, and keep a copy of anything you would be upset to lose.
>
> Every known issue is listed under [Limitations](#limitations).

## Features

**Encryption**

| Format | Read | Write |
| --- | --- | --- |
| BitLocker | Yes | Yes |
| LUKS1, LUKS2 | Yes | Yes |
| LVM inside LUKS | Yes | Yes |

**Filesystems**

| Format | Read | Write |
| --- | --- | --- |
| NTFS | Yes | Yes |
| ext2, ext3, ext4, btrfs, XFS | Yes | Yes |
| exFAT, FAT † | Yes | Yes |

**Disk images**

| Format | Read | Write |
| --- | --- | --- |
| IMG, DMG † | Yes | Yes |
| qcow2 | Yes | Yes |
| VMDK \* | Yes | Yes |
| VMDK, stream-optimized \* | Yes | No |
| VDI \* | Yes | Yes |
| VHD \* | Yes | Yes |
| VHDX \* | Yes | No |

† Supported by macOS natively.

\* Support for these formats is experimental. Writing to them has not been
extensively tested.

BitLocker volumes unlock with the volume password or a 48-digit recovery key.
NTFS opens whether or not Windows shut down cleanly. LVM is read as Ubuntu,
Debian, Mint and Fedora set it up, and several volumes on one drive unlock
together. A BitLocker or LUKS volume inside an image unlocks like one on a
drive.

[SPECS.md][specs] specifies every filesystem, encryption and image format, what
is written and what is not, and how each is read.

> [!WARNING]
> **Writing to qcow2, VMDK, VDI and VHD images is untested.** These drivers were
> written for Lukotta and are checked against `qemu-img` when the engine is
> built from source, but
> they have not been in use long enough to call them thoroughly tested. Writing
> to an image is at your own risk: open it read-only to copy files out safely,
> or make a backup first.

<details>
<summary>What the App Cannot Open</summary>

- Drives sealed to a TPM rather than a password, including Ubuntu's newer
  hardware-backed encryption
- LUKS volumes whose header is stored separately from the drive
- FileVault and encrypted disk images, which macOS opens itself
- Images that name another file: a VMware snapshot chain, a differencing VHD, a
  VHDX with a parent, or a qcow2 with a backing file. Lukotta opens no image
  that determines which other files are read
- A VHDX that was not shut down cleanly. Open it once in the virtual machine it
  belongs to, which writes back what it last held

</details>

## How It Works

Each volume you open gets a [libkrun][libkrun] microVM: a stripped Alpine root
filesystem, 512 MB, two virtual CPUs. The drive goes in as a block device, the
Linux kernel mounts it, and the volume is exported over NFS. macOS mounts that,
NFS being the one filesystem protocol it takes without a kernel extension.

`/dev/disk4s1` is `root:operator`, so a launchd daemon opens the device and
passes the descriptor to the microVM, which runs under your account. The app
never runs as root.

**Encryption.** [cryptsetup][cryptsetup] unlocks BitLocker in the guest with
the volume password or a 48-digit recovery key, producing `/dev/mapper/btlk0`:
a block device holding ordinary NTFS. LUKS1 and LUKS2 are the same path. The
passphrase reaches the guest through its environment, and nothing else of the
host's does. The machine is sized from the LUKS header, which records what the
key derivation needs.

**LVM.** Ubuntu, Debian, Mint and Fedora put LVM inside LUKS, so unlocking
exposes a volume group. One machine activates it and exports every logical
volume, because anylinuxfs locks whole physical partitions and several machines
wanting one partition would collide.

**NTFS.** Lukotta tries `ntfs3`, falls back to `ntfs-3g`, then to read-only.
ntfs3 is in the kernel: forty thousand deletions take seconds there and an hour
through FUSE. On a volume Windows left dirty, `ntfsfix` clears the flag and
rebuilds `$MFTMirr` from `$MFT`, gated on a dry run reporting it can process
both. A hibernated volume is refused; writing to one destroys the pending
memory image.

**Linux filesystems.** ext2/3/4, btrfs and XFS use the kernel's own drivers,
bare or inside LUKS.

**exFAT and FAT** are declined. macOS mounts them natively, and opening one
here would turn a local volume into a network one.

**Disk images.** [imago][imago], compiled into the engine, reads qcow2, VMDK,
VDI, VHD and VHDX. An image reaches the guest as a block device exactly as a
drive does, so a LUKS container inside a VMDK unlocks like one on a USB stick.
Images naming another file are refused: snapshot chains, differencing VHDs,
qcow2 with a backing file. Opening one lets a file choose which other files get
read.

**The NFS mount.** Every number was measured on real hardware. `dumbtimer`,
because the dynamic estimator otherwise collapses the retry interval to
milliseconds; a 60-second timeout; `mutejukebox`, which stops macOS announcing
a server that is only busy; a 32 KB write size, since a large write ahead of a
directory listing on one TCP connection is time the listing waits.

## Limitations

Where a fix is known, it is named.

**A file with a resource fork is silently dropped.** Copying it onto a Lukotta
volume creates nothing, and a folder copy still reports success. The macOS NFS
client keeps every other extended attribute in an AppleDouble file beside the
original and refuses `com.apple.ResourceFork` with `EINVAL`. No mount option
reaches it. Finder tags, quarantine flags and custom attributes are unaffected.

**`fsync` is not durable if the machine is killed.** Data an application was
told had been committed can be lost when the microVM dies abruptly. On ext4 and
XFS the file survives with a hole in it; on NTFS it can vanish. A normal eject
is safe: the app gives the machine twenty seconds to flush and never kills one
that is still writing. `fsync` on a device node returns success without
reaching the drive and `F_FULLFSYNC` fails there with `ENOTTY`, so the engine
now issues `DKIOCSYNCHRONIZECACHE`. That is not yet proven by measurement.

**The folder you are copying into is slow to list.** During a large copy it
takes seconds to refresh, occasionally much longer. Other folders answer
instantly, the copy is unaffected, and no error appears. READDIR over NFS
queues behind the write stream: 0.01 s inside the guest, 7 s across the mount.
Seven mount and driver settings were measured; one helped and is in use.

**RAID arrays work, but the app does not offer them yet.** Lukotta claims Linux
RAID partitions so macOS stops offering to initialise them. A two-disk RAID1
mounts through the engine and a copy onto it reads back byte-identical. `mdadm`
ships in the guest. Missing is the app constructing the identifier that opens
an array.

**Writing to virtual machine images is not thoroughly tested.** Reading is
exercised heavily; writing is not.

**ZFS is not supported.** Neither the packages nor the `zfs.ko` and `spl.ko`
modules ship in the guest. Carrying it is an open licence question, ZFS being
CDDL, as much as a technical one.

## Requirements

- An Apple Silicon Mac. Intel Macs are not supported
- macOS 15 Sequoia or later
- 260 MB of disk: 160 MB for the app, 100 MB for the Linux environment it unpacks
  on first use
- 30 MB of RAM per open drive sitting idle, and up to 450 MB for one being
  copied to
- Up to 12 drives can stay unlocked at once

## Languages

Lukotta is available in thirty-seven languages. English, and thirty-six more:

Albanian · Arabic · Bulgarian · Chinese (Simplified) · Croatian · Czech ·
Danish · Dutch · Estonian · Filipino · Finnish · French · German · Greek ·
Hebrew · Hindi · Hungarian · Indonesian · Italian · Japanese · Korean ·
Latvian · Lithuanian · Malay · Norwegian (Bokmål) · Polish ·
Portuguese (Portugal) · Romanian · Russian · Slovenian · Spanish · Swedish ·
Thai · Turkish · Ukrainian · Vietnamese

If a translation reads wrongly, or you would like one that is not listed here,
write to [support@lukotta.com][email] or to GitHub Issues. Corrections and
requests are both welcome.

## Installing

Download Lukotta from [Releases][releases], drag it to Applications, and open
it. It is signed and notarised.

Or with [Homebrew](https://brew.sh):

Release:

```bash
brew install --cask clementrahula/tap/lukotta
```

Pre-release (Beta):

```bash
brew install --cask clementrahula/tap/lukotta@beta
```

## Permissions

- **Full Disk Access**: macOS will not let any app read a drive's raw contents
  without it. It cannot be requested, so it has to be switched on by hand
- **Removable volumes**: requested by macOS the first time a drive is read
- **Administrator password**: asked for once when the background helper is set
  up. Lukotta never sees it

## Opening a Drive

Plug in the drive and pick it from the list. Type the password or paste the
recovery key. It appears in Finder under Locations.

For a disk image, choose **File → Open Disk Image…**, or **File → Open Drive…**
to see every disk attached to this Mac and what Lukotta can do with each.

Lukotta can also auto-mount what was open after a restart. Switch on **Open drives
again after restarting** at the top of Settings: it then opens in the background
when you log in and mounts the drives and images that were open, as they were.
A drive that needs a password comes back only if the password is saved in your
Keychain, and anything that is not connected is simply
passed over. It is off until you turn it on.

Lukotta remembers a passphrase in your Keychain when you ask it to.

> [!NOTE]
> The drive is handed to Finder over a local network connection, so it appears
> under Locations with a network icon. It reads, writes and ejects like any
> other drive. macOS offers no way to present it as a local disk.

## Uninstalling

Choose **Lukotta → Uninstall Lukotta…** from the menu bar. It says what it will
remove, then ejects anything open, unregisters the background helper, deletes
the Linux environment, and moves the app to the Bin.

If you asked Lukotta to remember any passphrases, it offers to delete those too
and names the drives they belong to. The offer is off by default: some are
48-digit recovery keys that might exist nowhere else.

## Building

```bash
./scripts/fetch-engine.sh    # download the pinned engine, verify checksums
./scripts/build-engine.sh    # optional: build the patched engine from source
./scripts/vendor-engine.sh   # stage it into vendor/
./build-app.sh               # compile, embed, sign, install
```

The engine step is optional. Skipping it produces a working app built on
upstream's binaries, which opens fewer image formats and says by name which ones
it cannot open. [patches/README.md][patches] describes each patch.

That builds `Drive Unlocker.app`. The name and logo are trademarks that the GPL
does not license, so a build carries them only when asked. The software is the
same either way, and [TRADEMARKS.txt][trademark] says what is permitted.

The whole path, including how to reproduce a released build, is in
[BUILDING.md][building]. To work on Lukotta, see [CONTRIBUTING.md][contributing].

## Privacy and Security

Lukotta collects nothing. It makes one request of its own, a daily check for
updates, which can be turned off. [PRIVACY.md][privacy] describes it.

Your passphrase is never written to disk in the clear and never appears in a
command line. [SECURITY.md][security] describes how it is handled, what the
privileged helper accepts, and where to report a fault.

## Licence

Copyright (C) 2026 Clement Rahula.

Lukotta is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. It is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See [the licence][licence] for the details, and
<https://www.gnu.org/licenses/> for the text of any later version.

Every source file carries `SPDX-License-Identifier: GPL-3.0-or-later`, except
those under `patches/`, which belong to other projects and carry theirs.
Complete source for every component is published with each release.

The name and the logo are trademarks, and are not covered by that licence. Fork
the code freely; give your version its own name. [TRADEMARKS.txt][trademark]
says what that means in practice.

[Licence][licence] · [Trademarks][trademark] · [Third-party notices][notices] ·
[Specs][specs] · [Releases][releases]

## The Name

Lúkotta is Finnish for "without a lock", from *lukko*, a lock, with the ending
*-tta* marking the absence of something. The stress falls on the first syllable,
as it always does in Finnish.

## Credits

Clement Rahula · [support@lukotta.com](mailto:support@lukotta.com) ·
[rahula.dev](https://rahula.dev)

The mounting is done by [anylinuxfs][anylinuxfs], written by nohajc. Updates use
[Sparkle][sparkle]. Lukotta is not affiliated with Microsoft, Apple, or the Linux
projects it works with.

Lukotta is developed and maintained using GenAI tools, mainly the Opus 5
and Fable 5 models from Anthropic.

[email]: mailto:support@lukotta.com
[releases]: https://github.com/clementrahula/lukotta/releases
[building]: BUILDING.md
[contributing]: CONTRIBUTING.md
[privacy]: PRIVACY.md
[security]: SECURITY.md
[licence]: LICENSE.txt
[trademark]: TRADEMARKS.txt
[notices]: THIRD_PARTY_NOTICES.md
[specs]: SPECS.md
[patches]: patches/README.md
[anylinuxfs]: https://github.com/nohajc/anylinuxfs
[libkrun]: https://github.com/containers/libkrun
[cryptsetup]: https://gitlab.com/cryptsetup/cryptsetup
[imago]: https://crates.io/crates/imago
[sparkle]: https://sparkle-project.org
