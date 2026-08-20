# FULocker — TODO

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
- [ ] **[you]** Re-grant Full Disk Access. The rename changed the bundle id and
      path, so the old grant no longer applies. Remove the stale
      `BitLocker Mounter` and `anylinuxfs` rows while you are there.
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
- [ ] **[both]** **Give the source offer a real address.**
      `THIRD_PARTY_NOTICES.md` promises source "to the address in the repository
      README", and the README currently contains no contact at all. Either add
      one you will honour for three years, or mirror the upstream tarballs and
      drop the offer.
- [ ] **[me]** **Make the build reproducible.** `vendor/` is gitignored and
      `vendor-engine.sh` stages from whatever anylinuxfs happens to be installed
      on the build machine, so nobody else can build FULocker and v1.0.1 cannot
      be rebuilt identically. Pin and checksum the upstream artefacts — the
      hashes are still in git history in the old `bootstrap.sh`.
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
- [ ] **[me]** Trademark line: state that FULocker is unaffiliated with and not
      endorsed by Microsoft. Describing it as "for BitLocker drives" is ordinary
      nominative use and fine.
- [ ] **[you]** Check whether the US export notification for publicly available
      encryption source applies to you (EAR §742.15(b), a one-time email with a
      URL). Published open source is generally exempt in the EU. Ten minutes,
      routinely skipped. Not legal advice.
- [ ] **[me]** Rename the repository to `fulocker` and give it a description; it
      is still `bitlocker-mac-gui` with an empty description.
- [ ] **[me]** Short privacy statement. It is a security tool that handles
      recovery keys — say plainly that nothing is transmitted anywhere.
- [ ] **[me]** Bundle full licence texts, not just links.

---

## 3. Correctness and robustness

- [ ] `Diagnosis.summarise` matches engine output by substring, so an upstream
      wording change silently degrades to raw output. Pin to exit codes where
      the engine provides them.
- [ ] Only the first mounted drive is resumed on launch; multiple simultaneous
      drives are not modelled.
- [ ] A plain NTFS drive is indistinguishable from BitLocker until an unlock is
      attempted, so the user finds out by failing. Probe the FVE signature once
      elevated and say so before asking for a credential.
- [ ] No CI. Nothing runs `tests/run-all.sh` or checks that the app builds.
- [ ] No crash reporting, and no in-app way to report a problem.
- [ ] No update mechanism. Sparkle is GPL-compatible but needs care.

---

## 4. Open question: the sidebar name

- [ ] Establish what the sidebar actually displays. Finder's own API reports the
      volume as `BACKUP`, which is the NTFS label from Windows — i.e. the
      drive's real name. If that is what you see, nothing is wrong. If it shows
      something like `disk4s1.local`, that is the NFS server name, derived from
      an internal `vm_hostname` with no CLI flag, and it needs fixing at source.

---

## 5. Nice to have

- [ ] "Unlock at login" or a remembered-drive convenience.
- [ ] Localisation and an accessibility audit.
- [ ] Clean up old residue on this machine: `~/Library/Application Support/
      BitLocker Mounter/` (83 MB download cache, an empty `secrets/` folder from
      an earlier design).

---

## 6. Strategic — the native UX project

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
