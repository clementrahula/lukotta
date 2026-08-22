# Plan

What is left to do. Completed work is not recorded here — the history is in git.

Items are marked **[you]** where they need credentials, a decision, or hardware
only you have; everything else is unassigned and can be picked up in any order.

---

## The eight before release — done

All eight are implemented. What they were, and what came out of them:

1. **`os.Logger`.** Everything is logged under the bundle's identifier, names
   and paths private, counts and states public. A bug report now carries the
   last fifteen minutes of what the app was actually doing.
2. **Tests for `DriveScanner`, `EngineEnvironment` and `Workspace`.** The
   parsing is separated from the two `diskutil` calls so it can be given
   captured output. Found that the partition UUID was read from only one of the
   two plists that carry it, and that a failure to unpack the Linux environment
   reported an empty string where tar's complaint should have been.
3. **Snapshot tests.** Twelve scenes × two appearances × two window sizes × two
   languages. Rendered through an off-screen `NSWindow`, because `ImageRenderer`
   comes back with the inside of a `ScrollView` empty and the drive list lives
   in one.
4. **The Full Disk Access check, off the main thread.** It was read on every
   switch back to the app, not only at launch. Also moved the healthy-launch
   mark earlier: a machine without the permission never reached it, so three
   launches on one would have rolled back a perfectly good version.
5. **Swift 6.** The real find was `Workspace`: made on the main actor, used by
   the background task running the mount, destroyed from the main actor on quit,
   with an unguarded flag.
6. **Telling NTFS from BitLocker.** The first sector is read by the helper —
   `/dev/diskNsM` is mode 640 root:operator, which Full Disk Access does not
   change. An unencrypted drive now says so, drops the password field and offers
   Open.
7. **`Diagnosis`.** Still matches text, because the engine exits 0 either way
   and there is nothing else to match. But the rules record whose words they
   are, and bumping `vendor/engine.lock` fails a test until someone has checked
   them — the silent part of the failure is what was wrong.
8. **Dynamic Type — not a thing on macOS.** See the note under Accessibility.
   The equivalent, text needing more room than English, is now a snapshot axis,
   and it immediately found the permission panel untranslated in all twenty-one
   languages and a truncated button in German.

### Everything that needs you, in one pass at the end

The work above is finished. What is left wants you at the keyboard with hardware
attached. Nothing has been unmounted in the meantime.

- ~~**Close the lid with a drive open.**~~ Done, and it worked: the drive was
  still there and still working afterwards. The microVM survives a sleep and the
  NFS client comes back on its own.
- **A BitLocker drive**, to prove the first-sector probe recognises one before a
  password is typed.
- **An unlock through the helper, end to end**, since the mount path was touched
  by the Swift 6 work and by the empty-credential route.
- **Anything wanting a drive ejected.** Nothing was ejected while this was going
  on; whatever needs it waits for you to say when.
- **Notarise, and take the screenshots.** Both are Stage 1 anyway.

---

## Stage 1 — Ship the first release

Nothing below is optional. Until all of it is done there is no artefact that can
responsibly be given to anyone.

- **[both] The hardware pass**, listed above. Sleep, the two drive formats, an
  unlock end to end. Nothing ships before it.
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

- **Handle "already mounted by macOS"** rather than only diagnosing it. The
  engine has `--remount`; the app could offer it.
- **A crash with a fallback mount open still produces the system's "server
  connections interrupted" dialog.** Stale mounts are cleared on launch and when
  a drive disappears, so the window for it is small, and mounts made through the
  helper survive the app going away entirely. What is left is the crash itself,
  and it cannot be intercepted — only avoided by unmounting first.
- **Check engine log growth.** The engine writes to `~/Library/Logs` and
  `~/.anylinuxfs` regardless of anything the app does. Confirm the logs rotate.
- **Port `validate-key.sh` to Swift**, removing a shell dependency and a process
  spawn from the unlock path for thirty lines of logic.
- **Wire CI back up.** It ran on every push, failed, and sent the failures out
  as email rather than to anyone who was looking. Turned off until it can be
  pinned to the toolchain the app is really built with: the errors it found were
  real ones the newer local SDK does not produce, and they are fixed but
  unconfirmed against the older one.

## Testing

- **Nothing outstanding.** `DriveScanner`, `EngineEnvironment` and `Workspace`
  are covered, and `scripts/snapshots.sh` renders every screen in two
  appearances, two window sizes and two languages.

## Accessibility and localisation

- **Dynamic Type does not exist on macOS, and this is not a task.** SwiftUI
  ignores `dynamicTypeSize` there: the same text laid out at `.xSmall`,
  `.large`, `.accessibility1` and `.accessibility5` comes back the same height
  to the pixel, and `NSFont.preferredFont(forTextStyle: .body)` is a fixed 13pt.
  The system's per-app text size reaches a list of Apple's own applications and
  not this one. What does happen here is text needing more room than English
  gives it, and the snapshots render in German for exactly that reason.
- **Checkbox rows report no description** to the accessibility tree — a SwiftUI
  `Form` puts the label and the switch side by side as siblings. The label is
  read, so this is a polish item rather than a barrier.

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

## More formats

Built. [FORMATS.md](FORMATS.md) has the reasoning; what shipped:

- **Container files open with no privilege at all.** The user attached the file,
  so the device is theirs and the mount is a user mount. Neither the helper nor
  an authorisation prompt is involved. They land under `~/Volumes` rather than
  `/Volumes`, which is the one visible difference.
- **qcow2**, read natively by the engine. Never attached, since macOS cannot
  read one — the path goes to an unprivileged engine, which is what made this
  cheap rather than a decision about what root may do.
- **exFAT is handed to macOS**, which mounts it locally and read-write, with the
  sheet explaining why rather than appearing to do nothing.
- **VMDK is written but not applied.** See [patches/](patches/): libkrun already
  reads it and the patch is six lines, but building the engine from source stops
  on a missing Homebrew LLVM, and carrying our own build changes how the app is
  vendored, reproduced and licensed. A deliberate decision, not a side effect.

Still open, in rough order of worth:

- **Stream-optimized VMDK.** The compressed form, which is what `ovftool` writes
  into an OVA. Every grain is deflated and preceded by a marker, so it is a
  different thing to read from the sparse form now supported. Refused by name.
- **VHDX.** The last of the virtual disk formats, and the only one left
  unopened. It is most of the work and all of the risk — a log that must be
  replayed, or an image that was not cleanly closed silently reads stale — and
  it may never be worth it. Everything around it is done: fixed VHD is raw with
  a footer after it, and VDI and dynamic VHD are read by drivers of ours in
  imago. See [FORMATS-VM.md](FORMATS-VM.md).
- **A VM disk holding APFS, FAT or exFAT** should be decoded, attached and
  mounted locally rather than served over NFS — the same rule that sends exFAT
  to macOS.
- **libkrun opens files an image names.** A qcow2 backing file or a VMDK
  descriptor's extents are opened by libkrun itself, so a hostile image can make
  the guest read what the user can read. Container files run unprivileged, which
  bounds it, but it is worth a look before accepting more formats.

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

## Shipping without having been tried

- **The plain-NTFS path.** The first-sector probe recognises three formats, and
  only BitLocker can be tried here — there is no unencrypted NTFS drive to hand.
  So the note saying a drive is not encrypted, and opening one with no password,
  are written and unit-tested but have never run against a real disk. The
  identification itself is covered both ways by tests over synthetic boot
  sectors, and a drive that reads as anything unrecognised is left alone
  entirely, so the failure mode is the screen saying nothing rather than saying
  something wrong.

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
