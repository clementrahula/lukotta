# Lukotta — TODO

Consolidated from the release review and PRODUCTION-READINESS.md.
Ordered by what blocks what. Last updated 20 August 2026 (v1.0.1).

Legend: **[you]** needs your credentials or a decision · **[me]** can be done
without either · **[both]** needs a decision, then implementation.

---

## 0. Tonight — before anything else

- [ ] **[you]** Do one real unlock with the current build. ZFS was stripped from
      the Linux image and that change touches the guest boot path; it has not
      been verified against the drive. If it fails, revert first with
      `BLM_KEEP_ZFS=1 ./vendor-engine.sh && ./build-app.sh`.
- [ ] **[you]** Re-grant Full Disk Access. The bundle id is now
      `com.clementrahula.lukotta` and the app is `Lukotta.app`, so any earlier
      grant no longer applies. This is the last identity change. Remove the stale
      `BitLocker Mounter`, `FULocker` and `anylinuxfs` rows while you are there.
- [ ] **[you]** Confirm what the Finder sidebar actually says, so the naming
      question can be closed (see §4).

---

## 1. Release blockers

Nothing ships until these are done.

- [ ] **[you]** **Notarise the app.** Confirmed state: `spctl` returns
      `rejected — Unnotarized Developer ID`, no stapled ticket. Users will see
      "Apple cannot check it for malicious software". Needs an Apple ID, an
      app-specific password and the Team ID, then `notarytool submit --wait`
      followed by `stapler staple`. The hypervisor entitlement should pass, but
      submission is how that gets confirmed.
- [ ] **[me]** Write the notarisation script so the above is one command.
- [ ] **[you]** **Make the repository public.** GPL-3 binaries entitle
      recipients to the corresponding source; a private repo plus a public
      binary is a violation from the first download.
- [x] Dropped the three-year written offer in favour of GPL-3 §6(d) /
      GPL-2 §3 same-place distribution. §6(a) and §6(b) are both written for
      object code "embodied in a physical product"; for a download, publishing
      source beside the binary discharges the obligation immediately and starts
      no clock. `lukotta@rahula.dev` stays as an ordinary contact.
- [x] `scripts/collect-sources.sh` assembles the corresponding source:
      Lukotta via `git archive`, the pinned anylinuxfs tarball, the Linux kernel
      matching the version detected in the shipped image, and the Alpine aports
      recipes for every shipped package. It exits non-zero if anything cannot be
      fetched, so a release cannot quietly ship without complete source.
- [ ] **[me]** Attach its output to the release next to the .dmg, and say so in
      the release notes — §6(d) requires the source be offered *from the same
      place* as the binary.
- [ ] **[me]** Resolve each Alpine package's upstream tarball from its APKBUILD
      rather than shipping only the aports recipes. Recipes are the "scripts
      used to control compilation"; the upstream tarballs are the source proper.
- [x] Guest image trimmed by `tools/trim-image.py`, which resolves the apk
      dependency graph and keeps only the closure of the BitLocker, NTFS, NFS
      and mount tooling: 76 packages down to 58, 25.6 MiB of files removed, and
      the package database rewritten so it still describes what ships. LVM,
      RAID, btrfs, squashfs and ZFS are gone. `BLM_NO_TRIM=1` ships the lot.
      Note python3 and krb5 stay: `nfs-utils` depends on them.
- [ ] **[me]** **Make the build reproducible.** `vendor/` is gitignored and
      `vendor-engine.sh` stages from whatever anylinuxfs happens to be installed
      on the build machine, so nobody else can build Lukotta and v1.0.1 cannot
      be rebuilt identically. Pin and checksum the upstream artefacts — the
      hashes are still in git history in the old `bootstrap.sh`.
- [ ] **[both]** **Decide the first public version number.** The repo is at
      1.0.1 because the bump script was exercised during setup. A first public
      release is usually 1.0.0, or 0.x while the network-drive limitation and
      untested sleep/wake behaviour stand.
- [ ] **[me]** **Produce a distributable artefact.** The build emits an `.app`,
      not something you can attach to a release. Needs a signed `.dmg` with a
      drag-to-Applications layout — and the DMG must itself be notarised, not
      just the app inside it.

---

## 2. Strongly recommended before release

- [ ] **[both]** Test sleep/wake and drive-removal-while-mounted. An NFS soft
      mount that hangs produces beachballs with no explanation. If it is bad,
      detect it and say something useful.
- [ ] **[me]** Real progress for the first unlock — it unpacks ~95 MB behind a
      single status line and looks frozen.
- [ ] **[me]** Trademark line: state that Lukotta is unaffiliated with and not
      endorsed by Microsoft. Describing it as "for BitLocker drives" is ordinary
      nominative use and fine.
- [ ] **[you]** Check whether the US export notification for publicly available
      encryption source applies to you (EAR §742.15(b), a one-time email with a
      URL). Published open source is generally exempt in the EU. Ten minutes,
      routinely skipped. Not legal advice.
- [ ] **[me]** Rename the repository to `fulocker` and give it a description; it
      is still `bitlocker-mac-gui` with an empty description.
- [ ] **[me]** Short privacy statement, with lukotta@rahula.dev as the contact. It is a security tool that handles
      recovery keys — say plainly that nothing is transmitted anywhere.
- [ ] **[me]** Bundle full licence texts, not just links.
- [ ] **[me]** Add `CHANGELOG.md`. Needed independently of Sparkle, which uses
      release notes in the appcast.
- [ ] **[me]** Write `RELEASING.md`: vendor, build, test, bump, notarise, DMG,
      appcast, tag, publish. Right now that sequence exists only in my head and
      in scattered scripts.
- [ ] **[me]** **Document a clean uninstall.** Removing the app leaves
      `~/.anylinuxfs` (95 MB), any engine logs, and a Full Disk Access entry.
      For a tool sold on leaving no unnecessary traces, "drag to Trash" being
      insufficient is a real gap — either document it or add a Remove
      Everything action.

---

## 3. Updates — Sparkle

Ship this with 1.0.x, not later. Without it, every user of a released build is
stranded on whatever version they first downloaded, and this app asks for Full
Disk Access and root — exactly the kind of thing that needs a working patch
path.

**Licensing is clear.** Sparkle 2.x is MIT, with bundled bsdiff (BSD-2-Clause),
sais-lite (MIT) and an Ed25519 implementation (zlib-style). All permissive and
all compatible with distributing Lukotta under GPL-3-or-later. Runtime
requirement is macOS 12+, below our 15.0 floor.

- [ ] **[me]** Embed `Sparkle.framework` in `Contents/Frameworks/` and add it to
      the inside-out signing pass in `build-app.sh`. Sparkle 2 ships XPC
      services and an installer helper that each need signing with the hardened
      runtime, so this is more than dropping in a framework.
- [ ] **[you]** Generate the EdDSA key pair with Sparkle's `generate_keys`, and
      **back up the private key**. It lives in the login keychain. If it is
      lost, every existing install becomes unupdatable — there is no recovery,
      because clients only trust that one key.
- [ ] **[me]** Add `SUFeedURL` and `SUPublicEDKey` to `Info.plist`.
- [ ] **[both]** Decide where the appcast lives. GitHub Releases plus an
      `appcast.xml` in the repo works and costs nothing; a custom domain is
      nicer if the project ever moves off GitHub. The feed URL is baked into
      every shipped build, so changing it later strands old installs — pick a
      URL you can keep.
- [ ] **[me]** Wire `generate_appcast` into the release flow so publishing is
      one command that builds, signs, generates the appcast and produces deltas.
- [ ] **[me]** **Delta updates are not optional here.** The bundle is 154 MB and
      roughly 150 MB of that is the engine and Linux image, which change rarely.
      Without deltas every bug-fix release is a 154 MB download for a few
      kilobytes of changed Swift. `generate_appcast` produces and signs them
      automatically.
- [ ] **[me]** Guard against updating mid-mount. Installing over the app while a
      drive is unlocked would pull the engine out from under a running microVM.
      Defer installation until nothing is mounted, using the same
      `EngineStatus.current()` check the quit handler uses.
- [ ] **[me]** Add Sparkle and its bundled components to
      `THIRD_PARTY_NOTICES.md`; the generator currently only covers the engine
      and the Linux image.
- [ ] Note the ordering: **notarisation must come first.** Sparkle verifies both
      its EdDSA signature and the Apple code signature, and the artefact it
      downloads has to be notarised or Gatekeeper rejects the installed update.

---

## 4. Branding and assets

Renamed to **Lukotta** ("without a lock", Finnish) on 20 August 2026. Bundle id
is now `dev.rahula.lukotta`.

- [x] Official logo stored at `assets/brand/lukotta-logo.jpg`, with the mark
      extracted to `assets/brand/lukotta-mark.png`.
- [x] Icon calibrated against the artwork by `tools/analyse-logo.swift`, which
      measures the mark rather than eyeballing it: charcoal `#444953` (median of
      971 interior samples), cream `#FBF6F2`, corner radius 0.174 of width, cut
      width 0.053, and a cut centre that tracks linearly from 0.343 to 0.473
      across as it descends. Still a redraw, but a measured one.
- [ ] **[you]** Supply vector or high-resolution artwork. The source is a
      1448×1086 JPEG, so the mark crops to 448 px — below the 1024 px an icns
      needs, and JPEG-compressed. The icon is therefore drawn rather than
      derived from the file. An SVG or a 1024 px+ PNG would let the icon come
      straight from the artwork, and is worth having as the brand master
      regardless.
- [ ] **[me]** Use the wordmark. The logo lockup includes "lukotta" set in a
      light geometric sans; it belongs in the About panel and at the top of the
      README, neither of which currently show any branding.
- [x] Brand colours and the mark's construction are recorded in
      `tools/make-icon.swift` and reproducible via `tools/analyse-logo.swift`.
- [ ] **[me]** Write them up in a short `assets/brand/README.md` so they are
      findable without reading Swift.

---

## 5. Icons and caching

- [x] Dock and Finder showed a stale icon after the renames. The bundle was
      correct — identical hash in `assets/`, `/Applications` and the delivered
      copy — so this was LaunchServices and IconServices caching the icon
      registered under the earlier names at the same path. Fixed by re-running
      `lsregister -f`, clearing `~/Library/Caches/com.apple.iconservices.store`
      and restarting Dock and Finder. A stale `FULocker.app` registration was
      also unregistered.
- [ ] **[me]** Fold that into the build: after installing to `/Applications`,
      `touch` the bundle and re-register it, so a rebuilt icon shows up without
      anyone having to know about icon caches.
- [ ] **[you]** Confirm the Dock and Finder now show the Lukotta mark. If a
      stale icon persists, logging out and back in clears the last cache layer.

---

## 6. Menus and settings

The app has no persisted preferences at all and no Settings scene, which is the
right default — it does one thing and auto-scales the VM to the host, so there
is nothing worth a knob. The gaps below are menu-bar and per-mount issues rather
than reasons to add a preferences window.

- [ ] **[me]** The licence is unreachable. `LICENSE` and
      `THIRD_PARTY_NOTICES.md` ship inside the bundle but nothing opens them.
      For a GPL app that is a compliance-adjacent gap as well as a courtesy —
      add an About panel and a Help menu entry that open both.
- [ ] **[me]** No Help menu and no in-app support path. Point it at the issues
      page once the repo is public, and at lukotta@rahula.dev.
- [ ] **[me]** Read-only unlock, as a checkbox on the unlock screen — *not* a
      global setting. Mounting a suspect or failing drive without writing to it
      is a real use case, and it is a per-drive decision, so it belongs next to
      the credential field. The engine already supports it.
- [ ] **[me]** "Don't ask again" on the eject-on-quit dialog, which is better
      than a preferences pane for a three-button prompt someone will always
      answer the same way. This is the first thing that needs persisted state.
- [ ] **[me]** A minimal `Settings` scene becomes necessary when Sparkle lands
      (§3): convention is "Check for Updates…" in the app menu plus an
      "Automatically check for updates" toggle, and that toggle needs somewhere
      to live. One pane, two rows — resist growing it further.

Deliberately **not** exposed: vCPU count, RAM and NFS transfer sizes. These are
derived from the host and no user can set them better than the machine can.

---

## 7. Correctness and robustness

- [ ] `Diagnosis.summarise` matches engine output by substring, so an upstream
      wording change silently degrades to raw output. Pin to exit codes where
      the engine provides them.
- [ ] Only the first mounted drive is resumed on launch; multiple simultaneous
      drives are not modelled.
- [ ] A plain NTFS drive is indistinguishable from BitLocker until an unlock is
      attempted, so the user finds out by failing. Probe the FVE signature once
      elevated and say so before asking for a credential.
- [ ] No CI. Nothing runs `tests/run-all.sh` or checks that the app builds.
- [ ] **Check engine log growth.** The engine writes to `~/Library/Logs` and
      `~/.anylinuxfs` and ignores `$HOME`, so nothing the app does can redirect
      it. Confirm the logs are bounded rather than growing without limit — "no
      random logs and rubbish" is only true if they rotate.
- [ ] Handle "already mounted by macOS" rather than only diagnosing it. The
      engine has `-r/--remount`; today the user is told to eject in Finder and
      retry, which the app could do for them.
- [ ] Test coverage is pure logic only: `Credential`, `EngineStatus`,
      `Diagnosis`, `Permissions`. Untested: `DriveScanner` plist parsing,
      `EngineEnvironment` unpacking, `Workspace` lifecycle, and the construction
      of the privileged mount command — the last of these being the highest-risk
      code in the app.
- [ ] Port `helpers/validate-key.sh` to Swift. Shelling out to bash for
      credential validation means a process spawn and a shell dependency on the
      unlock path, for logic that is thirty lines.
- [ ] No crash reporting, and no in-app way to report a problem.

---

## 8. Open question: the sidebar name

- [ ] Establish what the sidebar actually displays. Finder's own API reports the
      volume as `BACKUP`, which is the NTFS label from Windows — i.e. the
      drive's real name. If that is what you see, nothing is wrong. If it shows
      something like `disk4s1.local`, that is the NFS server name, derived from
      an internal `vm_hostname` with no CLI flag, and it needs fixing at source.

---

## 9. Nice to have

- [ ] "Unlock at login" or a remembered-drive convenience.
- [ ] Localisation and an accessibility audit.
- [x] Icon legibility at 16 px checked — the Lukotta mark still reads as itself.
- [ ] Clean up old residue on this machine: `~/Library/Application Support/
      BitLocker Mounter/` (83 MB download cache, an empty `secrets/` folder from
      an earlier design).

---

## 10. Website and visibility

### Website — built, needs switching on

`docs/` holds a single-page site using the brand palette and mark, with a
`CNAME` for **lukotta.rahula.dev**. It states the Full Disk Access requirement
and the network-drive limitation up front rather than burying them.

- [ ] **[you]** Enable GitHub Pages: repository **Settings → Pages**, source
      **main branch, /docs folder**. Note that **Pages on a private repository
      needs a paid plan** — on a free account the repo must be public first,
      which is already release blocker §1.
- [ ] **[you]** Add the DNS record at `rahula.dev`:
      `lukotta` **CNAME** → `clementrahula.github.io`. GitHub issues the TLS
      certificate automatically once that resolves; then tick **Enforce HTTPS**.
- [ ] **[me]** Add screenshots of the app once there is a release to point at —
      the page currently describes the product without showing it.
- [ ] The Download button points at `/releases/latest`, so it 404s until the
      first release exists.

### Awesome lists

Worth doing, but only once the repo is public and has a tagged release with a
README and screenshots — every list rejects submissions that lack those.

- [ ] **[me]** `serhii-londar/open-source-mac-os-apps` — the closest fit, a
      curated list of open-source macOS applications.
- [ ] **[me]** `jaywcjlove/awesome-mac` — very large and widely read; has an
      explicit open-source marker.
- [ ] **[me]** `iCHAIT/awesome-macOS`.
- [ ] Consider Alternativeto and the r/macapps launch post at the same time;
      "open source, no macFUSE, no kernel extension" is the differentiator to
      lead with, given every comparable tool is closed and paid.

---

## 11. Platform and feature expansion

### Intel / universal binary — probably not worth it

The Swift side is trivial: build for `x86_64-apple-macos15.0` as well and `lipo`
the results. Everything else is the problem.

- [ ] Check whether anylinuxfs publishes an **x86_64 bottle**. The pinned hashes
      were `arm64_tahoe` and `arm64_sequoia` only, and the original bootstrap
      hard-failed on anything but arm64, which suggests upstream is
      Apple-Silicon-only.
- [ ] Check **libkrun on Intel macOS**. It uses Hypervisor.framework, which
      Intel Macs have, but libkrun's macOS support has been arm64-centric. This
      is the gating question — no hypervisor, no product.
- [ ] Budget for **a second guest image**. The Alpine rootfs and the kernel
      inside libkrunfw are both `aarch64`; Intel needs an x86_64 pair, adding
      roughly 100 MB and taking the bundle past 250 MB, plus a second set of
      sources to mirror.

Weigh against a shrinking audience: the last Intel Macs shipped in 2020 and the
deployment floor is already macOS 15. **Verify the libkrun question before
committing to any of it** — if that fails, the rest is moot.

### LUKS / Linux encrypted volumes — genuinely promising

Much better value than Intel. The engine already does this: `cryptsetup` is
already in the guest image (it is what unlocks BitLocker), and anylinuxfs
advertises LUKS decryption in its own `list` command. Ubuntu's full-disk
encryption is LUKS, typically LUKS → LVM → ext4.

- [x] `lvm2`, `e2fsprogs` and `btrfs-progs` restored to the trim roots — LVM is
      the layer Ubuntu, Debian, Fedora and openSUSE all put inside LUKS. Image
      is 66 packages, 150 MB; ZFS stays out.
- [x] `DriveScanner` now recognises Linux partition types alongside
      `Microsoft Basic Data`, and each drive carries a `VolumeKind` so the UI
      can say "BitLocker or NTFS" / "LUKS or Linux filesystem" — honest about
      what cannot be known before unlocking.
- [x] `-t ntfs3` is no longer forced. Microsoft volumes try ntfs3 then fall back
      to ntfs-3g; Linux volumes get no override so the engine detects ext4,
      btrfs or xfs itself. Both attempts run inside one elevated command, so it
      is still a single authorisation.
- [x] UI copy no longer says BitLocker throughout.
- [ ] **[you]** **Capture `anylinuxfs list --decrypt` output from a real
      Ubuntu-encrypted drive.** This unblocks the LVM work below; it is the one
      thing needed and cannot be synthesised here.
- [ ] **[you]** **Test against a real LUKS drive.** None of the above is
      verified — there is no Linux volume here. An Ubuntu USB installer or a
      LUKS-formatted stick would confirm detection, unlock and the LVM path.
- [ ] Confirm the guest kernel has ext4/btrfs/xfs built in. The userland tools
      are present, but mounting depends on the kernel in libkrunfw, which was
      not checked.
- [ ] **[me]** **LUKS-inside-LVM is NOT wired — and it is the default layout on
      Ubuntu, Debian, Mint, Pop and Fedora.** Confirmed from the engine itself:
      LVM must be addressed explicitly as `lvm:<vg-name>:diskXsY:<lv-name>`, and
      its help says "see `list` command output for available volumes". It runs
      `vgchange -ay` and `lsblk -O --json` during `list`, so `list --decrypt`
      is the discovery step. Lukotta currently passes the bare `/dev/diskXsY`,
      which unlocks the container and then finds an LVM physical volume rather
      than a filesystem.

      The flow needs to be: unlock and list, parse the volume group and logical
      volume names, then mount `lvm:<vg>:<disk>:<lv>` — all inside one elevated
      command to preserve the single authorisation. Where a container holds
      several logical volumes (root, home, swap) the user has to pick one.

      **Deliberately not written blind.** The parser has to match the real
      output of `list --decrypt` against an LVM stack, and that output has
      never been seen here. Writing it from a guess would most likely be wrong
      in the exact case that matters most. Capture the output from a real
      Ubuntu-encrypted drive first, then implement against it.
- [ ] Out of scope, worth stating in the UI: TPM-sealed volumes (Ubuntu 23.10+
      experimental FDE) and detached LUKS headers cannot be unlocked here.

Strategically this is the stronger move: it widens the product beyond BitLocker
and differentiates it from iBoysoft and M3, which are BitLocker-only. Most of
the work is detection and UI, not new engine capability.

---

## 12. Strategic — the native UX project

Not a release task. This is the separate project described in
PRODUCTION-READINESS.md §7, and it is what would make the product genuinely
differentiated.

- [ ] Re-test FSKit on macOS 26.6.1 with Apple's FSKitSample. Third-party FSKit
      extensions were broken on 26.1 and 26.2 (`fskitd` rejecting unprivileged
      clients), but those reports predate this build. One afternoon, and it
      decides whether the good path is open at all.
- [ ] Test whether Apple's read-only NTFS kext probes a *locked* BitLocker
      partition. It contains FVE metadata rather than an NTFS boot sector, so it
      may not — which would sidestep the module-masking problem entirely.
- [ ] Prototype BitLocker unlock natively with `libbde` (LGPL-3.0). Useful under
      every path, and independent of the mount mechanism.
- [ ] Decide FSKit (own NTFS) vs DriverKit (licensed NTFS). If DriverKit, start
      the Apple entitlement conversation early — block-storage entitlements need
      approval.

Note that NTFS read/write is the dominant cost under every option, and that
going native also removes the GPL constraint, making a proprietary product
possible.
