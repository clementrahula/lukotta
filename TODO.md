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
- [ ] **[me]** **Build the source archive into the release process.** This is
      what makes §6(d) true rather than aspirational: every release carrying a
      binary must carry source for Lukotta *and* for every embedded GPL
      component — anylinuxfs, libkrunfw and its kernel, and each GPL package in
      the Alpine image. GPL-3 §6(d) permits a third-party server with clear
      directions, but GPL-2's equivalent paragraph says "the same place", so
      the GPL-2 components (kernel, busybox, ntfs-3g, nfs-utils, mdadm, …)
      should be mirrored by us.
- [ ] **[me]** **Shrink the guest image.** The compliance surface is 76 Alpine
      packages because anylinuxfs is a general-purpose filesystem tool. Lukotta
      needs cryptsetup, NTFS and NFS tooling, mount and their dependencies —
      likely under half of that. Less to mirror, a smaller download, and a
      smaller attack surface, for the same functionality.
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

## 5. Menus and settings

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

## 6. Correctness and robustness

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

## 7. Open question: the sidebar name

- [ ] Establish what the sidebar actually displays. Finder's own API reports the
      volume as `BACKUP`, which is the NTFS label from Windows — i.e. the
      drive's real name. If that is what you see, nothing is wrong. If it shows
      something like `disk4s1.local`, that is the NFS server name, derived from
      an internal `vm_hostname` with no CLI flag, and it needs fixing at source.

---

## 8. Nice to have

- [ ] "Unlock at login" or a remembered-drive convenience.
- [ ] Localisation and an accessibility audit.
- [x] Icon legibility at 16 px checked — the Lukotta mark still reads as itself.
- [ ] Clean up old residue on this machine: `~/Library/Application Support/
      BitLocker Mounter/` (83 MB download cache, an empty `secrets/` folder from
      an earlier design).

---

## 9. Strategic — the native UX project

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
