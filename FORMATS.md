# What Lukotta can open, and what it could

Three separate layers, and every question about "can it open X" is really a
question about which of them X lands in.

1. **The wrapper** — how the bytes are stored. A raw file, a DMG, a VM disk.
2. **The encryption** — LUKS, BitLocker, VeraCrypt, none.
3. **The filesystem** — ext4, NTFS, btrfs, HFS+.

A format is cheap to add when it lands in a layer that already has the machinery
and expensive when it does not. Everything below was checked against the engine
and the guest that ship in the app today, not recalled.

---

## What works now

**Wrappers.** Physical drives; raw image files (`.img`, `.dd`, anything
`cryptsetup luksFormat` produced); DMG, ISO, sparseimage and sparsebundle — all
of those because macOS attaches them and Lukotta hands the resulting device to
the engine.

**Encryption.** LUKS1, LUKS2, BitLocker.

**Filesystems**, from the guest kernel: ext2, ext3, ext4, XFS, btrfs, F2FS,
bcachefs, erofs, squashfs, vfat, exFAT, NTFS (ntfs3), and anything through FUSE.

---

## Already in the box, not yet reachable

The engine's cryptsetup is 2.8.6 and answers to more than we ask it:

    luks  luks1  luks2  plain  loopaes  tcrypt  bitlk  fvault2

Two of those are formats Lukotta does not offer.

### TrueCrypt and VeraCrypt — `tcrypt`

No new dependency: the code is already in the guest, and cryptsetup's licence
(GPL-2.0-or-later) upgrades cleanly to this project's GPL-3.

The difficulty is not the decryption, it is that **a VeraCrypt volume cannot be
recognised**. It has no header signature by design — a volume is meant to be
indistinguishable from random bytes, which is the whole point of the format. So
nothing can probe it and say what it is. The user has to assert "this is
VeraCrypt", and then:

- the passphrase, plus optional keyfiles, plus an optional PIM;
- outer volume or hidden volume;
- system-encrypted volumes, which are a separate case again.

That is a screen of its own and a mode the app does not currently have. The
engine also has to be told to use tcrypt rather than probing, which means either
a custom action in its config or a change upstream.

**Cost:** medium. A few days. Most of it is interface and wording, not
plumbing, and it adds a concept — "tell me what this is" — that the app has so
far avoided needing.

### FileVault 2 — `fvault2`

Supported by cryptsetup since 2.6, and **only** the old Core Storage kind, on
HFS+. The FileVault that ships on modern macOS is APFS-based and is not covered
by anything outside Apple.

There is a harder blocker: cryptsetup would decrypt the container and then hand
back an HFS+ volume, and **the guest kernel has no hfsplus driver**. Adding one
means rebuilding libkrunfw, which is the kernel the whole app depends on.

**Cost:** large, for a small audience — an external drive encrypted by a Mac
running 10.7 to 10.12 and never re-encrypted since. Not worth it.

---

## Cheap and worth doing

### Encrypted DMG

macOS does all of it. `hdiutil attach -stdinpass` takes the password on stdin,
refuses a wrong one with a plain "Authentication error", and hands back a device
node exactly like an unencrypted image. Verified.

Nothing new is linked, nothing is shipped, no licence question arises. It is the
native encrypted-container format of the platform the app runs on, and it is the
one a Mac user is most likely to have.

**Cost:** small. The open panel already exists; this adds "is it encrypted?"
(`hdiutil imageinfo` says so), a passphrase prompt, and passing it on stdin.
Perhaps a day.

---

## Virtual machine disks

This is where the question gets interesting, because the engine is further along
than it looks.

| Format | Where it stands |
| --- | --- |
| **qcow2** | Fully supported by the engine, read and write. Its CLI takes `disk.qcow2@s1` directly. |
| **VMDK** | The engine's image layer reads it — the binary carries VMDK descriptor parsing and a "No VMDK write support" message — but `anylinuxfs` only exposes `Raw` and `Qcow2`, so it cannot be asked for. |
| **VHD / VHDX** | Nothing anywhere in the stack. |
| **VDI** | Nothing anywhere in the stack. |

### The obstacle for qcow2, which is ours

macOS cannot attach a qcow2, so there is no device node, and Lukotta's whole
design is built on handing the helper a device node and never a path. Supporting
qcow2 means passing a user-chosen file path to a process running as root, which
is the one thing the current design deliberately avoids.

It is not unsolvable — the path can be validated, and the helper composes its own
commands — but it is a real widening of what root is asked to do, and it deserves
to be decided rather than slipped in.

**Cost:** small in code, medium in judgement.

### The right shape for the rest

Rather than teaching the Mac side to read every format, **put the format support
in the guest**. There is already a Linux VM; it can be given the file and left to
work out what it is. `qemu-img` and `qemu-nbd` between them read VHD, VHDX, VMDK,
VDI, qcow2 and more, and adding them to the Alpine image is a package, not a
port.

That also settles the licence question in the cleanest possible way. QEMU is
**GPL-2.0-only**, which cannot be combined with GPL-3 code into one work — but
running as a separate program inside a virtual machine is not combining. It is
the same footing as the Linux kernel and busybox already in the bundle.

**Cost:** medium. Days rather than weeks. Adds perhaps 10 MB to a bundle already
past 150 MB, and one more thing to keep patched.

The alternative is the libyal libraries — `libvhdi`, `libvmdk`, `libqcow` — which
are **LGPL-3.0-or-later** and so link cleanly into a GPL-3 application. They are
clean, small C libraries, and they are also **alpha** by their own authors'
description, and would run in the host process against a file the user chose.
QEMU in the guest is the safer bet.

---

## Legally

Nothing here is a problem, and one thing is worth stating plainly because it
looks like one and is not.

- **QEMU is GPL-2.0-only.** It cannot be linked into this app. It can be shipped
  beside it and executed as its own program, which is exactly what the kernel,
  busybox and apk-tools in the guest already are. Keep it a separate binary and
  there is no question to answer.
- **libyal (libvhdi, libvmdk, libqcow, libbde) is LGPL-3.0-or-later** — compatible
  with GPL-3, linkable, no obligation beyond the usual notices.
- **cryptsetup is GPL-2.0-or-later**, which upgrades to GPL-3. Already shipped.
- **VeraCrypt** is dual-licensed Apache-2.0 and TrueCrypt Licence 3.0, and the
  TrueCrypt half is the awkward one — but none of its code is needed. cryptsetup's
  `tcrypt` is an independent implementation.
- **Names.** VeraCrypt, VMware, Microsoft and Apple are other people's
  trademarks. Saying "opens VMware disks" is nominative use and fine; putting
  their marks on the app is not.
- **Export.** More decryption does not change the position. The app already
  handles encryption and the analysis does not turn on how many formats.

---

## If it were up to me

1. **Encrypted DMG.** A day, no new dependencies, the format Mac users actually
   have.
2. **Decide the path-to-root question.** Everything below waits on it, and it is
   a decision rather than a task.
3. **qemu-img and qemu-nbd in the guest**, which brings VHD, VHDX, VMDK and VDI
   at once, and qcow2 without the engine's CLI having to change.
4. **VeraCrypt**, if anyone asks for it. It is the largest of these because it
   needs a way for the user to say what a file is, which nothing else here does.

Not worth doing: FileVault 2, blocked behind a kernel rebuild for a format Apple
replaced a decade ago. APFS encryption, which nothing outside Apple reads.
Windows EFS, which is per-file and needs a domain key.
