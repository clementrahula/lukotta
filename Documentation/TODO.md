# Plan

What is left to do. Completed work is not recorded here — the history is in git.

Items are marked **[you]** where they need credentials, a decision, or hardware
only you have; everything else is unassigned and can be picked up in any order.

---

## Stage 1 — Ship the first release

Nothing below is optional. Until all of it is done there is no artefact that can
responsibly be given to anyone.

- **[you] Notarise the app.** `spctl` currently rejects it as an unnotarised
  Developer ID build, so a downloader is told macOS cannot check it for
  malicious software. Needs an Apple ID, an app-specific password and the team
  identifier, then `notarytool submit --wait` and `stapler staple`.
- Write the notarisation script so the above is a single command.
- **Produce a distributable artefact.** The build emits a `.app`; a release
  needs a signed `.dmg` with a drag-to-Applications layout. The DMG must itself
  be notarised, not only the app inside it.
- **[you] Make the repository public.** GPL-3 binaries entitle recipients to the
  corresponding source. A private repository and a public binary cannot coexist.
- **Attach the source archive to each release** and say so in the release notes.
  `scripts/collect-sources.sh` produces it; nothing yet publishes it. Section 6(d)
  requires the source to be offered from the same place as the binary, so this is
  what makes the claim in the notices true.
- **Make the build reproducible.** `vendor/` is gitignored and
  `scripts/vendor-engine.sh` stages from whatever runtime happens to be installed
  on the build machine. Nobody else can build Lukotta, and a released version
  cannot be rebuilt. Pin and checksum the upstream artefacts.
- **[both] Choose the first public version number.** The current number reflects
  development churn rather than a release.

---

## Stage 2 — Before handing it to strangers

- **[both] Test sleep/wake and drive removal while mounted.** Neither is handled.
  An NFS mount that hangs after a lid close gives no explanation. Needs someone
  present to close a lid and pull a cable.
- **Guard against updating mid-mount.** Installing over the app while a drive is
  open would pull the engine out from under a running virtual machine. Defer
  installation using the same check the quit handler uses.
- **[you] Generate the Sparkle signing keypair** with `scripts/sparkle-keys.sh`
  and back up the private key. It is unrecoverable: lose it and every installed
  copy becomes permanently unupdatable.
- **[both] Decide where the appcast lives.** The feed URL is compiled into every
  build, so changing it later strands existing installs.
- **Wire `generate_appcast` into the release flow**, including delta updates.
  Without them every bug-fix release is a 154 MB download for a few kilobytes of
  changed code.
- **Add Sparkle to the third-party notices.** It is MIT with BSD-2 and zlib
  components, and is not currently listed.
- **[you] Check whether the US export notification applies** to publishing
  encryption software from a US-hosted repository. Published open source is
  generally exempt in the EU. Not legal advice.
- **Add a trademark line**: Lukotta is unaffiliated with and not endorsed by
  Microsoft. Describing it as "for BitLocker drives" is ordinary nominative use.
- **Provide a clean uninstall.** Removing the app leaves the registered helper,
  `~/.anylinuxfs`, and a privacy entry behind. `SMAppService.unregister` is
  wired but nothing calls it.
- **[you] Have the licence position reviewed** by someone qualified. The
  analysis is careful, but it is engineering judgement.

---

## Stage 3 — Reach

- **Enable GitHub Pages** for the site in `docs/` — **[you]** repository
  settings, source `main` / `docs`. Pages on a private repository needs a paid
  plan, so this follows the repository going public.
- **[you] Add the DNS record**: `lukotta` CNAME → `clementrahula.github.io`,
  then enforce HTTPS once the certificate is issued.
- **Add screenshots** to the site and the README. The download button points at
  `/releases/latest` and will 404 until a release exists.
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

- **A drive dropped abruptly produces a macOS dialog we cannot restyle.** When
  the virtual machine goes away with an NFS mount still active, macOS reports
  "server connections interrupted". It cannot be intercepted; it can only be
  avoided by unmounting first. Mounts made through the helper survive the app
  quitting, so this only affects the fallback path — but a crash still triggers
  it. Worth checking for a stale mount on launch and offering to clear it.
- **Handle multiple simultaneous drives.** Only the first mounted drive is
  resumed on launch.
- **Distinguish plain NTFS from BitLocker before unlocking.** Today the user
  finds out by failing. Probing the FVE signature once elevated would tell them.
- **Handle "already mounted by macOS"** rather than only diagnosing it. The
  engine has `--remount`; the app could offer it.
- **Replace substring matching in `Diagnosis`.** Engine output is matched by
  text, so an upstream wording change silently degrades to raw output.
- **Check engine log growth.** The engine writes to `~/Library/Logs` and
  `~/.anylinuxfs` regardless of anything the app does. Confirm the logs rotate.
- **Move the Full Disk Access check off the main thread.** It performs file I/O
  during launch.
- **Adopt Swift 6 language mode.** Strict concurrency flags real issues in
  `AppModel`'s detached tasks. Deliberately deferred so that concurrency
  semantics did not change during a structural refactor.
- **Add structured logging** with `os.Logger`, so support reports contain more
  than whatever is still in memory.
- **Port `validate-key.sh` to Swift**, removing a shell dependency and a process
  spawn from the unlock path for thirty lines of logic.

## Testing

- **Cover what is currently untested**: `DriveScanner` plist parsing (needs only
  fixtures), `EngineEnvironment` unpacking and `Workspace` lifecycle (temp
  directories).
- **Add snapshot tests for the interface.** Several layout and state regressions
  reached the screen because nothing checks rendering.
- LUKS layouts can be exercised without hardware: `scripts/make-test-volumes.sh`
  builds LUKS1, LUKS2, direct and LVM variants inside the guest, unprivileged.
- **[you] Test against a real LUKS drive.** Detection, unlock and the LVM path
  are implemented and verified against volumes built inside the guest, but never
  against real hardware.

## Accessibility and localisation

- **Audit with VoiceOver running** and test Dynamic Type at larger sizes. Labels
  exist; nothing has been verified with the assistive technology itself.
- **Extract the strings table** with `genstrings`. Every literal is already a
  translation key by virtue of SwiftUI, but no table is generated, so nothing can
  be translated yet.

## Interface

- **Read-only unlock**, as a checkbox on the unlock screen rather than a global
  setting: it is a per-drive decision, and mounting a failing drive without
  writing to it is a real need.
- **"Don't ask again" on the eject-on-quit dialog.**
- **A minimal Settings scene**, once Sparkle needs somewhere for its
  automatic-update toggle. One pane, two rows.
- **Remember window size and position**, the last drive used, and offer it first.
- The window leaves vertical slack on its shortest screen. Tolerable.

---

## Stage 4 — Larger bets

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

### Meet the drive before macOS does

Plugging in a BitLocker or LUKS drive gets the Finder dialog offering to
initialise it, which is the one action that would destroy it. Lukotta could
recognise the drive first and offer to open it instead. Needs a running
background presence and DiskArbitration; the dialog belongs to the system, so
the question is whether it can be pre-empted rather than answered.

### Read-only per drive

A choice at unlock, remembered per drive. The engine takes only a shared lock
on the device when mounting read-only, so this is also the one route by which
several volumes of one container could be opened as separate VMs.

---

## Waiting on you

- **Make the repository public.** GitHub Pages refuses a private repository on
  the current plan, so the project page and the appcast have nowhere to live
  until then, and without the appcast there is no update mechanism at all.
- **A second repository for the appcast**, served at
  lukotta-updates.rahula.dev. One Pages site takes one custom domain, so the
  feed cannot share a host with the website. Keeping them apart also keeps the
  feed off the proxied hostname, where an edge cache could serve a stale
  version and updates would quietly stop appearing.

- Approve the helper in Login Items and confirm an unlock runs without a
  password. The privileged path cannot be exercised here.
- Supply vector or high-resolution artwork. The source is a JPEG whose mark crops
  to 448 px, below what an icon needs, so the icon is drawn from measurements
  rather than derived from the file.
- Delete the stale privacy entries from earlier names, and the leftover
  `~/Library/Application Support/BitLocker Mounter/` directory.

---

## Documents to write

- `CHANGELOG.md` — needed independently of Sparkle, which uses release notes.
- `RELEASING.md` — vendor, build, test, bump, notarise, package, appcast, tag,
  publish. That sequence currently exists only as scattered scripts.
- `PRIVACY.md`, published at lukotta.rahula.dev and linked from the About sheet.
  Needed even though nothing is collected: the app handles disk encryption keys,
  asks for Full Disk Access, and can store a credential in the Keychain.
- `assets/brand/README.md` — the palette and the mark's construction, so future
  assets stay consistent without reading Swift.

---

## Known limitations

Not tasks. These are properties of the design, worth stating so they are not
rediscovered as bugs.

- **The volume appears as a network drive.** macOS offers no supported way to
  mark an NFS mount local. Only Stage 4 changes this.
- **Full Disk Access cannot be requested.** No API exists; it is granted by hand.
  The app detects the refusal and explains it.
- **The drive's name in Finder is only correct from the second unlock onward.**
  The label is not knowable until the volume is open, which is after the share
  has been named.
- **Apple Silicon and macOS 15 or later**, and no Mac App Store: sandboxed apps
  cannot read raw devices or elevate, quite apart from the licence.
- **TPM-sealed volumes and detached LUKS headers cannot be opened.**
