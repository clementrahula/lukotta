# BitLocker Mounter — production readiness, licensing and market

Written 19 August 2026, against the state of the repo at that date. Findings
about licensing are a careful engineering read of the licences involved, not
legal advice; the App Store and GPL section in particular is worth putting in
front of a solicitor before money changes hands.

---

## 1. The short answers

| Question | Answer |
| --- | --- |
| Must this be open source? | **Yes.** We ship GPL-3.0 binaries inside the app bundle. |
| Can it go on the Mac App Store? | **No** — blocked twice over, licence *and* sandbox. |
| Can it be sold for money? | **Yes**, the GPL permits it, but buyers get source and may redistribute. |
| Do similar apps exist? | **Yes** — at least five commercial ones, plus a free CLI tool. |
| Is it production ready today? | No. It works, but see §6. |

---

## 2. What we actually ship, and under what licence

The app is no longer a downloader; everything is embedded in the bundle. That
makes us a *distributor* of each component below, with the obligations that
carries.

### Host side (inside `Contents/Resources/engine/`)

| Component | Version | Licence | Notes |
| --- | --- | --- | --- |
| anylinuxfs | 0.19.0 | **GPL-3.0-or-later** | The engine. Decisive for everything below. |
| libkrun / libkrunfw | bundled in anylinuxfs | **GPL-2.0-only AND LGPL-2.1-only** | Bundles a Linux kernel image. |
| Linux kernel (in libkrunfw) | — | **GPL-2.0-only** | Binary distribution obliges us to supply matching source. |
| libblkid (util-linux) | — | LGPL-2.1 | The single external dylib we link. |

### Guest side (the Alpine rootfs archive)

Taken from `/etc/apk/world` in the shipped image:

| Package | Licence |
| --- | --- |
| busybox, apk-tools, mdadm, nfs-utils, btrfs-progs, squashfs-tools | GPL-2.0 |
| **bash** | **GPL-3.0-or-later** |
| cryptsetup | GPL-2.0-or-later + LGPL-2.1-or-later |
| ntfs-3g, ntfs-3g-progs | GPL-2.0 |
| lvm2 | GPL-2.0 / LGPL-2.1 |
| util-linux (blkid, lsblk, mount) | GPL-2.0 / LGPL-2.1 / BSD |
| musl | MIT |
| **zfs** | **CDDL-1.0** |

Two of these deserve singling out:

- **zfs is CDDL-1.0**, which the FSF considers GPL-incompatible. It ships in the
  Alpine image because upstream anylinuxfs wants ZFS support. *We do not need
  ZFS at all* — this is a BitLocker/NTFS tool. Removing it from the rootfs
  sidesteps a genuine licence-conflict argument and shrinks the bundle.
- **bash is GPL-3.0-or-later**, so even the guest image is not GPL-2-only.

### What this means concretely

1. **The distributed work must be GPL-3.0-compatible.** Our Swift code does not
   *link* anylinuxfs — we exec it as a separate process, which is the strongest
   argument for it being an independent work. But we ship it inside our bundle,
   the app is functionally useless without it, and it is not plausibly "mere
   aggregation" in the FSF's sense. The defensible position is to licence the
   whole thing GPL-3.0-or-later. The repo already carries GPL-3.0, so this
   costs nothing — it just has to stay that way.
2. **We owe recipients source code**, for our own code *and* for every GPL
   binary shipped: anylinuxfs, the Linux kernel inside libkrunfw, and every GPL
   package in the rootfs. A public repo covers our part; the rest needs either
   mirrored source tarballs or a written offer valid for three years.
   `THIRD_PARTY_NOTICES.txt` currently points at upstream URLs, which is
   **not sufficient** on its own for GPL-2 §3 — upstream URLs can vanish.
3. **No additional restrictions.** No DRM, no licence keys that prevent
   redistribution, no anti-copying measures on the GPL parts.

---

## 3. Mac App Store: not viable

Two independent blockers, either of which alone is fatal.

**Licence.** Apple's App Store terms impose usage rules and DRM that conflict
with GPL §6 and the "no further restrictions" clause. This is settled by
precedent: VLC was pulled from the iOS App Store in January 2011 after a
copyright-infringement notice from one of its developers, on exactly this
basis, and had been removed from the Mac App Store earlier.

**Sandboxing.** Mac App Store apps must be sandboxed. This app cannot be:

- it reads raw `/dev/diskNsM` nodes, unavailable in the sandbox;
- it requires **Full Disk Access**, which sandboxed apps cannot hold;
- it elevates to root to mount, and MAS forbids installing privileged helpers.

Even a permissively licensed rewrite would hit the sandbox wall. **Direct
distribution with Developer ID + notarisation is the only route**, which is what
the build already produces.

---

## 4. Charging for it

The GPL explicitly permits selling copies. What it forbids is restricting what
buyers do afterwards. So:

- ✅ Sell the notarised binary, at any price.
- ✅ Charge for support, updates, a hosted licence server, priority fixes.
- ❌ Prevent a buyer from passing on the binary *and* the source.
- ❌ Licence keys that would stop redistribution of the GPL parts.

Practically: anyone who buys it may legally republish it for free. That is
survivable — plenty of GPL software sells on convenience, notarisation, and
support — but it rules out a scarcity-based business model. The realistic
options are paid-binary/free-source, donations, or a support/pro tier around
non-GPL added value.

**If you want a proprietary product**, the GPL dependency has to go entirely:

| Path | Cost |
| --- | --- |
| Own BitLocker layer (AES-XTS, FVE metadata) + licensed NTFS driver | High: months, plus per-unit NTFS licensing from Paragon or Tuxera |
| `libbde` (LGPL-3.0) for BitLocker + commercial NTFS | Medium: LGPL allows proprietary use if dynamically linked and relinkable |
| Keep GPL, sell anyway | Zero engineering, accepts redistribution |

Note that dropping anylinuxfs also means dropping the microVM, which is what
forces the network-drive presentation (§5). The two problems share a solution.

---

## 5. Competitive landscape

Similar apps do exist — several, all commercial and closed-source.

| Product | Mounts as | Notes |
| --- | --- | --- |
| **iBoysoft BitLocker for Mac** | Physical *or* virtual | Own driver. Its "File Manager" mode claims to need neither a system extension nor Full Disk Access. Apple Silicon through M5. |
| **M3 BitLocker Loader** | Physical | Own driver, marketed on read/write speed. |
| **Hasleo BitLocker Anywhere** | Virtual | Uses macFUSE. Can also encrypt/decrypt. |
| **iSumsoft BitLocker Reader** | Virtual | M1/M2 only. |
| **UUByte BitLocker Geeker** | Virtual | Beginner-oriented. |
| **dislocker** | Virtual (FUSE) | Free, open source, **command line only**, needs Homebrew + macFUSE. |

Two things follow.

**The "no similar apps" premise is wrong**, but the *interesting* gap is real:
every free/open option is a command-line tool, and every GUI option is paid,
closed, and mostly built on macFUSE. A polished, open, notarised GUI that needs
no kernel extension is a genuine niche.

**Our weakest point against them is presentation.** iBoysoft and M3 mount as
*physical* drives using their own drivers. We mount over NFS from a microVM, and
upstream anylinuxfs states plainly: *"by design, any mounted volume is seen by
macOS as a network drive shared by our virtual machine."* That is architectural,
not a bug, and not fixable by mount flags — macOS exposes no way to mark an NFS
mount local. Closing that gap means replacing the microVM approach with a real
filesystem driver (FSKit on macOS 15+, or a licensed NTFS driver), which is the
same work as escaping the GPL.

Our advantages: no macFUSE, no kernel extension, no system extension approval,
Apple Silicon native, and open source.

---

## 6. What still needs doing

### Bugs and correctness

- [ ] **Sidebar name** — unresolved. Finder's API reports the volume as its NTFS
      label, but the sidebar reportedly shows something more technical. Need the
      exact string to tell whether it is the label or the NFS server name
      (`disk4s1.local`, derived from an internal `vm_hostname` with no CLI flag).
- [ ] **Eject is wrong.** `AppModel.eject` calls `diskutil unmount`, which drops
      the NFS mount but leaves the microVM running. Should call
      `anylinuxfs unmount` and then `stop`.
- [ ] **No VM shutdown on quit.** Quitting the app orphans the VM.
- [ ] **Drive removal while mounted** is not handled; NFS will hang on a soft
      timeout rather than reporting anything useful.
- [ ] **Sleep/wake** untested — the NFS mount very likely does not survive it.
- [ ] `Mounter.discoverMountPoint` parses `/sbin/mount` text and the engine
      transcript. Fragile; prefer `anylinuxfs status`, which reports the mount
      point directly.
- [ ] `Diagnosis.summarise` maps engine strings to messages by substring, so an
      upstream wording change silently degrades to raw output.
- [ ] Deployment target is macOS 14, but the engine bottles are Sequoia/Tahoe
      and `Permissions`/mount paths assume 15+. Raise it to 15.0 and mean it.

### Build and release

- [ ] **A clean checkout cannot build the app.** `vendor/` is gitignored and
      `vendor-engine.sh` copies from whatever happens to be installed on the
      developer's machine. Reproducible builds need pinned, checksummed
      upstream artefacts — the hashes still in `helpers/bootstrap.sh` are the
      right starting point.
- [ ] **Notarisation.** The app is Developer ID signed but unnotarised, so
      `spctl` rejects it. Anyone who downloads it gets a Gatekeeper warning.
      Needs `notarytool` with an app-specific password, and stapling.
- [ ] No CI. Nothing runs the test suite or checks the build.
- [ ] No update mechanism (Sparkle would need care under GPL, but is fine).
- [ ] No crash reporting.

### Dead code and hygiene

- [ ] **The repo contains two products.** The original bash launcher
      (`BitLocker Mounter`), `helpers/bootstrap.sh`, `helpers/runtime-ready.sh`,
      `helpers/alfs-proxy.sh` and `build.sh` are all superseded by the Swift app
      and its embedded engine. The only survivor still used at runtime is
      `helpers/validate-key.sh`. Decide: delete, or keep a documented CLI path.
- [ ] **The tests test the dead product.** All five suites exercise the shell
      launcher and bridge. There are **no tests for the Swift app** — not for
      credential normalisation, drive scanning, diagnosis mapping, or mount
      argument construction. This is the biggest quality gap in the repo.
- [ ] Old residue on dev machines: `~/Library/Application Support/BitLocker
      Mounter/` (83 MB download cache, an empty `secrets/` folder from an
      earlier design) and a stale `anylinuxfs` row in Full Disk Access.
- [ ] Strip **zfs** from the Alpine image (see §2) — removes a CDDL/GPL conflict
      and shrinks the download.

### Licence compliance before any public release

- [ ] Ship a complete written offer for source, or mirror the source tarballs
      for anylinuxfs, libkrunfw + its kernel, and every GPL package in the
      rootfs.
- [ ] Regenerate `THIRD_PARTY_NOTICES.txt` from the actual embedded contents —
      it still describes the old downloaded layout, including components we no
      longer ship (anylinuxfs-gui, gettext, json-c, libunistring).
- [ ] Include full licence texts in the bundle, not just links.

### UX still open

- [ ] First unlock unpacks ~95 MB with only a status line; needs real progress.
- [ ] No handling for a drive that is plain NTFS rather than BitLocker — the
      user finds out by failing to unlock.
- [ ] No "unlock at login" / re-unlock convenience.
- [ ] No localisation, no accessibility audit.

---

## 7. Escaping the network drive — native volume research

The goal: the drive appears as a real local disk, with the Finder behaviour that
follows from that (proper sidebar entry, rename, Get Info, eject, Time Machine
eligibility). Researched 19 August 2026.

### Why it is a network drive today

Not a bug and not a mount flag. Upstream anylinuxfs states it outright: *"by
design, any mounted volume is seen by macOS as a network drive shared by our
virtual machine."* The drive is read inside a Linux microVM and re-exported over
NFS to localhost. macOS offers no supported way to mark an NFS mount local —
there is no `local` option in `mount_nfs` and `MNT_LOCAL` is not settable from
user space. **Any fix means replacing the transport, not configuring it.**

### The three real options

#### A. FSKit filesystem extension — the strategic answer, currently blocked

FSKit is Apple's user-space filesystem framework, introduced in Sequoia and
usable from **macOS 15.4**. It is the sanctioned, kext-free replacement for
macFUSE, and its volumes mount as genuine local volumes. Modules are signed with
the `com.apple.developer.fskit.fsmodule` entitlement.

Two obstacles, one of them serious:

- **Third-party FSKit extensions are currently broken on macOS 26.** `fskitd`
  rejects unprivileged clients outright — the log line is literally
  `Hello FSClient! entitlement no`. Confirmed broken on 26.1 (25B78) and 26.2
  (25C56), and it breaks *Apple's own FSKitSample* too, so it is not an
  implementation error. An Apple DTS engineer's position as of July 2025: "more
  bugs have been found so you're going to need to wait for more fixes." **This
  machine runs 26.6.1, so the first thing to do is re-test — the status above
  predates it.**
- **Apple's built-in NTFS kext masks third-party NTFS modules.** Kexts probe
  before FSKit modules, so a third-party NTFS module never gets a look in via
  DiskArbitration, and `mount -F` reportedly fails on real (non-RAM) disks.

  *But this may not apply to us.* A locked BitLocker partition contains FVE
  metadata, not an NTFS boot sector. Apple's NTFS driver should decline to probe
  it, which could leave the field clear for our module. That is a cheap and
  high-value experiment.

#### B. DriverKit virtual block device — plausible, gated by Apple

`IOUserBlockStorageDevice` (BlockStorageDeviceDriverKit) lets a user-space
system extension present a block storage device. Expose the *decrypted* volume
as a real `/dev/diskN` and let macOS mount the filesystem on it — the truest
"physical disk" result, and almost certainly what iBoysoft and M3 do.

Three catches:

- Block-storage DriverKit entitlements are **restricted and require Apple's
  approval**, which is a business dependency, not an engineering one.
- DriverKit deliberately has **no filesystem or network access**, so the
  extension cannot read the source disk itself. It needs an app-side user client
  to feed it blocks — workable, but it puts an IPC hop in the data path.
- macOS's own NTFS is **read-only**, so write support still needs a licensed
  driver or our own implementation.

#### C. macFUSE — rejected

A kernel extension. On Apple Silicon it requires reduced security and a recovery
-mode dance. This is precisely the experience you would be trying to beat, and
it is what Hasleo makes users do.

### The cost nobody escapes: NTFS read/write

All three paths converge on the same wall. Both native options remove the
microVM, and with it `ntfs-3g` — the thing currently providing read/write. So a
native product needs:

| Layer | Options | Difficulty |
| --- | --- | --- |
| BitLocker unlock | `libbde` (**LGPL-3.0**, usable in a proprietary app if dynamically linked and relinkable), or own AES-XTS + FVE parser | Tractable — the format is documented |
| NTFS read/write | License Paragon or Tuxera (per-unit), or implement it | **The dominant cost** |

Reading NTFS is a known quantity; *writing* it correctly — journal, MFT, sparse
files, compression, hard links — is where filesystem projects go to die. This is
the real gate on "perfect native UX", not the mount mechanism.

One upside worth noting: **going native also escapes the GPL.** libbde is
LGPL-3.0 and a licensed NTFS driver is commercial, so a native rewrite makes a
proprietary, sellable product possible — §4's option B and this section's option
A/B are the same project.

### Suggested order of work

1. **Re-test FSKit on 26.6.1** with Apple's FSKitSample. One afternoon, and it
   decides whether path A is open at all.
2. **Test whether Apple's NTFS kext probes a locked BitLocker partition.** If it
   does not, the masking problem is moot for our case.
3. Prototype BitLocker unlock natively with `libbde` — independent of the mount
   mechanism, and useful under every path.
4. Only then decide between FSKit (own NTFS) and DriverKit (licensed NTFS), and
   start the Apple entitlement conversation early if it is DriverKit.

Until at least step 1 clears, the NFS approach stays, and the network-drive
presentation with it.

## 8. Recommendation

Two coherent products, and it is worth picking deliberately:

**A. Open-source utility.** Keep the GPL, keep the microVM, fix §6, notarise,
ship free or paid-binary. Low cost, honest, fills the real gap (every other free
option is CLI-only). Accepts the network-drive presentation permanently.

**B. Native product.** Replace anylinuxfs with a native BitLocker layer plus
FSKit or DriverKit and an NTFS driver (§7). Removes the GPL constraint *and* the
network-drive problem in one move, and is the only route to the native UX you
are aiming at. Months of work, gated today by an Apple FSKit bug and, on the
DriverKit route, by Apple entitlement approval. NTFS write support is the
dominant cost.

Option A is a few weeks. Option B is a company. The current codebase is a good
option A and a reasonable prototype for option B, but it cannot become option B
incrementally — the engine is the thing that would have to go.
