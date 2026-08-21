# Plan

What is left to do. Completed work is not recorded here — the history is in git.

Items are marked **[you]** where they need credentials, a decision, or hardware
only you have; everything else is unassigned and can be picked up in any order.

---

## Order of work

Eight things stand between here and a public release, and they are not
independent. This is the order they are being done in, and why that order.

**Phase 1 — instruments and safety nets.** Nothing user-visible changes.

1. `os.Logger`, first. Additive, changes no behaviour, and it is the thing that
   says what happened during everything that follows — including the sleep test,
   which would otherwise produce an anecdote rather than evidence.
2. Tests for `DriveScanner`, `EngineEnvironment` and `Workspace`. Fixtures only.
   These three sit directly under what phases 2 and 3 disturb.
3. Snapshot tests, with baselines captured from the interface **as it stands**.
   This is the one item with a hard deadline: capture them after a UI change and
   the change is what gets enshrined.

**Phase 2 — the structural change, while there is time for it to settle.**

4. The Full Disk Access check, off the main thread. Small, self-contained, and a
   concurrency change — so it goes immediately before the language-mode switch
   rather than being reasoned about twice.
5. Swift 6 language mode. The largest and riskiest item, so it goes as early as
   the safety nets allow and as far from the release as possible. Everything in
   phase 3 is then written under the strict rules instead of retrofitted to them.

**Phase 3 — behaviour, on a base that has stopped moving.**

6. Telling plain NTFS from BitLocker before the unlock.
7. `Diagnosis` without substring matching — after 6, not before. Two of the
   cases it currently guesses at exist only because the app lets someone try to
   unlock something that was never encrypted. Fix that first and the replacement
   is written once, against a smaller problem.

**Phase 4 — polish, checked by phase 1.**

8. Dynamic Type at larger sizes, rendered through the snapshot harness at
   several text sizes so it stays fixed. Then one translation sweep for whatever
   strings phase 3 added — new sentences cost twenty-one translations each, so
   they are written once and translated together.

### Everything that needs you, in one pass at the end

Nothing here is done piecemeal. The work above is finished first, and then the
whole of it is tried in a single sitting:

- **Close the lid with a drive open**, and see whether the microVM survives, the
  NFS client recovers on its own, and how long it takes.
- **A plain NTFS drive and a BitLocker drive**, to prove the probe tells them
  apart rather than merely believing it does.
- **Anything needing a drive to be ejected.** Nothing is unmounted while the
  work is going on. Whatever wants an eject waits for this pass and for you to
  say when.
- **Notarise, and take the screenshots**, which are Stage 1 anyway.

---

## Stage 1 — Ship the first release

Nothing below is optional. Until all of it is done there is no artefact that can
responsibly be given to anyone.

- **[both] Close the lid with a drive open, and see what happens.** The handling
  is written: nothing is unmounted for sleep, the free-space poll stops so the
  wake window is not spent queueing calls at a mount that cannot answer yet, and
  on waking each mount is asked whether it is alive — from a separate process, so
  a wedged one cannot take the app with it — every few seconds for a minute
  before it is treated as gone. What has never been observed is a real sleep. The
  open questions are whether the microVM survives one at all, whether the NFS
  client recovers on its own once it does, and how long that takes. Until then
  the grace period is a guess.
- **[you] Notarise a build.** `spctl` rejects the installed copy as an
  unnotarised Developer ID build, so a downloader is told macOS cannot check it
  for malicious software. Everything around it is written: the whole sequence is
  `LUKOTTA_NOTARY_PROFILE="lukotta" ./scripts/release.sh`, which refuses to
  finish rather than producing an unnotarised bundle. It needs the login keychain
  unlocked, so it cannot run from a locked Mac.
- **[you] Take the screenshots.** The README, the site and every listing in
  Stage 2 want them and none has one: the drive list, an unlock, and a drive open
  with several volumes, in both light and dark appearance. The site's download
  button points at `/releases/latest` and 404s until a release exists.
- **[both] Choose the first public version number.** `VERSION` says 1.7.0, which
  reflects development churn rather than a release.
- **[you] Make the repository public.** GPL-3 binaries entitle recipients to the
  corresponding source. A private repository and a public binary cannot coexist.
- **Build a `.dmg` in the release flow.** Every release ships one. The archive
  Sparkle updates from stays a `.zip` — that is the format it installs — so the
  release produces both, and the DMG is notarised and stapled in its own right
  rather than inheriting it from the app inside. Drag-to-Applications layout,
  and the website's download button points at it.

---

## Stage 2 — Reach

- **Add delta updates to the release flow.** The appcast is generated and signed;
  deltas are not, so every bug-fix release is a 154 MB download for a few
  kilobytes of changed code.
- **[you] A second repository for the appcast**, served at
  `lukotta-updates.rahula.dev`. The feed URL is already compiled into every
  build, so this host is fixed. One Pages site takes one custom domain, so the
  feed cannot share a host with the website; keeping them apart also keeps the
  feed off the proxied hostname, where an edge cache could serve a stale version
  and updates would quietly stop appearing.
- **[you] Enable GitHub Pages** for the site in `docs/` — repository settings,
  source `main` / `docs`. Pages on a private repository needs a paid plan, so
  this follows the repository going public.
- **[you] Add the DNS record**: `lukotta` CNAME → `clementrahula.github.io`,
  then enforce HTTPS once the certificate is issued.
- **Look at the site rendered**, in both appearances. Its content is current and
  its markup parses, but nothing about how it looks has been seen.
- **Publish a Homebrew cask** so installation is `brew install --cask lukotta`.
  A personal tap first; `homebrew-cask` once there is a release history. Both
  expect a notarised app and a stable versioned download.
- **Submit to the awesome lists** — `serhii-londar/open-source-mac-os-apps`
  first, then `jaywcjlove/awesome-mac` and `iCHAIT/awesome-macOS`. All require a
  public repository, a tagged release and screenshots.
- Consider Alternativeto and an r/macapps post at the same time. The angle worth
  leading with is that every comparable tool is closed and paid, and the free
  ones are command-line only.

---

## Correctness and robustness

- **Distinguish plain NTFS from BitLocker before unlocking.** Today the user
  finds out by failing. Probing the FVE signature once elevated would tell them.
- **Handle "already mounted by macOS"** rather than only diagnosing it. The
  engine has `--remount`; the app could offer it.
- **Replace substring matching in `Diagnosis`.** Engine output is matched by
  text, so an upstream wording change silently degrades to raw output.
- **A crash with a fallback mount open still produces the system's "server
  connections interrupted" dialog.** Stale mounts are cleared on launch and when
  a drive disappears, so the window for it is small, and mounts made through the
  helper survive the app going away entirely. What is left is the crash itself,
  and it cannot be intercepted — only avoided by unmounting first.
- **Check engine log growth.** The engine writes to `~/Library/Logs` and
  `~/.anylinuxfs` regardless of anything the app does. Confirm the logs rotate.
- **Move the Full Disk Access check off the main thread.** `refreshPermissions`
  opens the TCC database during launch.
- **Adopt Swift 6 language mode.** Every target is pinned to `.v5`. Strict
  concurrency flags real issues in `AppModel`'s detached tasks.
- **Add structured logging** with `os.Logger`, so support reports contain more
  than whatever is still in memory.
- **Port `validate-key.sh` to Swift**, removing a shell dependency and a process
  spawn from the unlock path for thirty lines of logic.

## Testing

- **Cover what is currently untested**: `DriveScanner` plist parsing (needs only
  fixtures), `EngineEnvironment` unpacking and `Workspace` lifecycle (temp
  directories). Nothing in `sources/LukottaTests` touches any of the three.
- **Add snapshot tests for the interface.** Several layout and state regressions
  reached the screen because nothing checks rendering.

## Accessibility and localisation

- **Test Dynamic Type at larger sizes.** The layouts are built for it but have
  only ever been seen at the default size.
- **Checkbox rows report no description** to the accessibility tree — a SwiftUI
  `Form` puts the label and the switch side by side as siblings. The label is
  read, so this is a polish item rather than a barrier.
- **Watch the step list in another language.** `MountStage.title` is looked up
  and the translations are present in the compiled tables, but seeing it requires
  a mount.

## Interface

- **Read-only unlock**, as a checkbox on the unlock screen rather than a global
  setting: it is a per-drive decision, remembered per drive, and mounting a
  failing drive without writing to it is a real need. It is also the one route by
  which several volumes of one container could be opened as separate virtual
  machines, since the engine takes only a shared lock on the device when mounting
  read-only.
- **"Don't ask again" on the eject-on-quit dialog.**
- **Remember the last drive used** and offer it first. Window size and position
  are already restored; the drive is not.
- The window leaves vertical slack on its shortest screen. Tolerable.

---

## Stage 3 — Larger bets

### A native volume, instead of a network share

The drive appears in Finder as a network volume because the engine re-exports it
over NFS. This is the single biggest difference between Lukotta and the paid
alternatives, and the only fix is to replace the transport.

- Re-test FSKit on the current macOS. Third-party FSKit extensions were broken on
  26.1 and 26.2 — `fskitd` rejects unprivileged clients, which breaks Apple's own
  sample too. One afternoon, and it decides whether the route is open.
- Test whether Apple's read-only NTFS kext probes a *locked* BitLocker partition.
  It holds FVE metadata rather than an NTFS boot sector, so it may not — which
  would sidestep the module-masking problem entirely.
- Prototype BitLocker unlock with `libbde` (LGPL-3.0). Useful under every route,
  and independent of the mount mechanism.
- Then choose: FSKit with an NTFS implementation of our own, or DriverKit with a
  licensed driver. DriverKit block-storage entitlements need Apple's approval, so
  that conversation starts early.

NTFS read/write is the dominant cost under either route. Going native also
removes the GPL constraint, so this and a proprietary product are the same
project.

### Intel support — probably not worth it

Gated on whether libkrun works on Intel macOS at all; if it does not, nothing
else matters. Would also need a second guest image and kernel, taking the bundle
past 250 MB, for an audience that stopped growing in 2020.

### Unlock at login

Needs both a stored credential and the helper. Worth designing carefully:
"convenient" and "a drive silently unlocks itself" are the same sentence.

Its companion: run at login, and open remembered drives as they are plugged in.
The same caution applies, and more so — nobody is watching when it happens.

### A binary dyld refuses to load

The app now keeps the outgoing bundle aside across an update and puts it back
after three launches that never reach a working window, which covers a version
that starts and fails. It cannot cover a version that never runs its own code at
all — that needs a watchdog outside the app, which means the privileged helper,
and a root daemon that can replace the contents of /Applications is a trade
worth deciding on before building it. The release smoke test already refuses to
publish a build that will not start here, which leaves only a build that starts
here and not on someone else's machine.

---

## Waiting on you

- **Supply vector or high-resolution artwork.** The source is a JPEG whose mark
  crops to 448 px, below what an icon needs, so the icon is drawn from
  measurements rather than derived from the file.
- **Delete the stale privacy entries from earlier names**, and the leftover
  `~/Library/Application Support/BitLocker Mounter/` directory, which is still
  there.

---

## Documents to write

- `RELEASING.md` — bump, tag, `scripts/release.sh`, commit the appcast to the
  updates repository, publish. `release.sh` performs the sequence but nothing
  states it in the order a person follows.
- `assets/brand/README.md` — the palette and the mark's construction, so future
  assets stay consistent without reading Swift.

---

## Known limitations

Not tasks. These are properties of the design, worth stating so they are not
rediscovered as bugs.

- **Encryption nested inside encryption is not opened.** A container holds one
  passphrase and every volume inside it is reached with that one, which is how
  LUKS and LVM fit together. A logical volume that is itself a LUKS container is
  a different matter: mounting it fails, the action aborts, and the drive falls
  back to opening a single volume. It should say so instead of looking broken.
  Several containers on one disk are fine — they are separate drives in the list
  and each asks for its own password.

- **The initialise dialog is only held back while Lukotta is running.** Plugging
  an encrypted drive into a Mac where Lukotta is closed still gets the system's
  offer to initialise it. Claiming the disk is what suppresses it, and a claim
  belongs to a running process. Doing better means a filesystem probe that lives
  outside the app — an FSKit module, or a bundle in /Library/Filesystems — and
  both are a larger commitment than the claim was.

- **The volume appears as a network drive.** macOS offers no supported way to
  mark an NFS mount local. Only Stage 3 changes this.

- **Full Disk Access cannot be requested.** No API exists; it is granted by hand.
  The app detects the refusal and explains it.

- **The drive's name in Finder is only correct from the second unlock onward.**
  The label is not knowable until the volume is open, which is after the share
  has been named.

- **Apple Silicon and macOS 15 or later**, and no Mac App Store: sandboxed apps
  cannot read raw devices or elevate, quite apart from the licence.

- **TPM-sealed volumes and detached LUKS headers cannot be opened.**
