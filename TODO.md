# Plan

What is left to do. **[you]** marks what needs credentials, a decision or
hardware only you have.

---

## Next

- [ ] **Finish the beta channel.** Left: **[you]** the DNS record for
  updates-beta.lukotta.com; an icon that tells the two apart in the Dock; a
  `release.sh` path publishing to the beta appcast with the same key; one real
  beta-to-beta update, applied and relaunched.

- [ ] **A harness for installs and updates.** Fresh install on a Mac that has
  never had anylinuxfs, and an update applied over each earlier state, checked
  for the helper replaced, the guest refreshed, passphrases and settings kept,
  mounts restored, and rollback. Run against beta before anything reaches prod.

- [ ] **Harmonise the end-to-end tests.** Every flow, not only the ones that
  succeed: a wrong passphrase, a drive unplugged mid-mount, a refused
  permission, a full ceiling, an eject that will not complete. On real screens.
  Beta gets the same set; a local build can do with less.

---

## Stage 1 — the first release

- [ ] **[both] The hardware pass.** A BitLocker drive, to prove the
  first-sector probe recognises one before a password is typed; an unlock
  through the helper end to end; anything wanting a drive ejected.
- [ ] **[you] Notarise a build.**
  `LUKOTTA_NOTARY_PROFILE="lukotta" ./scripts/release.sh`, with the login
  keychain unlocked.
- [ ] **[you] Screenshots** — the drive list, an unlock, a drive open with
  several volumes, in both appearances. The README, the site and every listing
  in Stage 2 want them.
- [ ] **[both] Choose the first public version number.**
- [ ] **[you] Make the repository public.** GPL-3 binaries entitle recipients to
  the source.
- [ ] **Build a `.dmg` in the release flow**, notarised and stapled in its own
  right, drag-to-Applications, with the site's download button pointing at it.
  Sparkle keeps updating from the `.zip`.

## Stage 2 — reach

- [ ] **Delta updates in the release flow.** Every fix is otherwise a 154 MB
  download for a few kilobytes.
- [ ] **[you] A second repository for the appcast** at updates.lukotta.com. The
  feed URL is compiled into every build. One Pages site takes one custom domain,
  and keeping the feed off the proxied host stops an edge cache serving a stale
  version.
- [ ] **[you] Enable GitHub Pages** for `docs/` — needs the repository public.
- [ ] **[you] DNS**: `lukotta` CNAME → `clementrahula.github.io`, then enforce
  HTTPS.
- [ ] **Look at the site rendered**, both appearances.
- [ ] **Publish a Homebrew cask.** A personal tap first, `homebrew-cask` once
  there is a release history.
- [ ] **Submit to the awesome lists** — `serhii-londar/open-source-mac-os-apps`,
  then `jaywcjlove/awesome-mac` and `iCHAIT/awesome-macOS`. Alternativeto and
  r/macapps at the same time: every comparable tool is closed and paid, and the
  free ones are command-line only.

---

## Correctness

- [ ] **A drive is not always identified again after being ejected and
  re-added** — the end-to-end run gives up after 60 seconds on it.
- [ ] **Handle "already mounted by macOS"** rather than only diagnosing it. The
  engine has `--remount`.
- [ ] **Check engine log growth.** The engine writes to `~/Library/Logs` and
  `~/.anylinuxfs` whatever the app does. Confirm the logs rotate.
- [ ] **Port `validate-key.sh` to Swift** — thirty lines, and it removes a
  shell dependency and a process spawn from the unlock path.
- [ ] **Wire CI back up**, pinned to the toolchain the app is built with. The
  errors it found were real and are fixed but unconfirmed against the older SDK.

## Interface

- [ ] **"Don't ask again" on the eject-on-quit dialog.**
- [ ] **Remember the last drive used** and offer it first. Window size and
  position already come back; the drive does not.

## Formats

- [ ] **Replay a VHDX log.** An image not shut down cleanly is refused by name
  rather than read stale. Replaying is a write, so it must be served in memory —
  `readv_special()`, with the log bounded by a length the header states. The
  obstacle is getting a genuinely dirty image to verify against.
- [ ] **VeraCrypt and TrueCrypt.** cryptsetup carries `tcrypt` and it is in the
  guest. Such a volume has no signature by design, so it needs the person to say
  a device holds one — an interface, not a dependency.
- [ ] **A VM disk holding APFS, FAT or exFAT** should be decoded, attached and
  mounted locally rather than served over NFS, the same rule that sends exFAT to
  macOS.
- [ ] **libkrun opens files an image names.** A qcow2 backing file or a VMDK
  descriptor's extents are opened by libkrun itself, so a hostile image can make
  the guest read what the user can read. Worth a look before accepting more
  formats.

## Release notes

- [ ] **Notes per release**, in a form GitHub shows on the release page and
  `scripts/appcast.py` puts into the feed as that version's description.

---

## Stage 3 — larger bets

### A native volume instead of a network share

The single biggest difference from the paid alternatives, and only replacing the
transport fixes it.

- [ ] Re-test FSKit on the current macOS. Third-party extensions were broken on
  26.1 and 26.2 — `fskitd` rejects unprivileged clients, which breaks Apple's own
  sample. One afternoon, and it decides whether the route is open.
- [ ] Test whether Apple's read-only NTFS kext probes a *locked* BitLocker
  partition. It holds FVE metadata rather than an NTFS boot sector, so it may
  not — which would sidestep module masking entirely.
- [ ] Prototype BitLocker unlock with `libbde` (LGPL-3.0). Useful under every
  route.
- [ ] Then choose: FSKit with our own NTFS implementation, or DriverKit with a
  licensed driver. DriverKit block-storage entitlements need Apple's approval, so
  that conversation starts early.

NTFS read/write dominates the cost either way. Going native also removes the GPL
constraint, so this and a proprietary product are the same project.

### Unlock at login

Needs a stored credential and the helper. "Convenient" and "a drive silently
unlocks itself" are the same sentence. Its companion — run at login, open
remembered drives as they are plugged in — more so, since nobody is watching.

### Intel

Gated on whether libkrun works on Intel macOS at all. A second guest image and
kernel would take the bundle past 250 MB, for an audience that stopped growing
in 2020.

### A binary dyld refuses to load

Rollback covers a version that starts and fails. A version that never runs its
own code needs a watchdog outside the app, which means the privileged helper —
and a root daemon that can replace the contents of /Applications is a trade to
decide on before building it.

---

## Waiting on you

- [ ] **Vector or high-resolution artwork.** The source is a JPEG whose mark
  crops to 448 px, so the icon is drawn from measurements rather than the file.
- [ ] **Delete the stale privacy entries from earlier names**, and the leftover
  `~/Library/Application Support/BitLocker Mounter/`.

## Documents to write

- [ ] `RELEASING.md` — bump, tag, `scripts/release.sh`, commit the appcast,
  publish. The script performs it; nothing states it in the order a person
  follows.
- [ ] `assets/brand/README.md` — the palette and the mark's construction.

---

## Untried

- **The plain-NTFS path.** The first-sector probe recognises three formats and
  there is no unencrypted NTFS drive to hand, so the note saying a drive is not
  encrypted, and opening one with no password, have never run against a real
  disk. Identification is covered both ways by tests over synthetic boot sectors,
  and anything unrecognised is left alone.

## Known limitations

Properties of the design, not tasks.

- **Encryption nested inside encryption is not opened.** A logical volume that is
  itself a LUKS container fails and the drive falls back to a single volume. It
  should say so rather than look broken. Several containers on one disk are fine.
- **The initialise dialog is only held back while Lukotta is running.** Claiming
  the disk suppresses it, and a claim belongs to a running process.
- **The volume appears as a network drive.** macOS offers no supported way to
  mark an NFS mount local. Only Stage 3 changes it.
- **Full Disk Access cannot be requested.** No API exists; the app detects the
  refusal and explains it.
- **The drive's name in Finder is right from the second unlock onward.** The
  label is not knowable until the volume is open, which is after the share is
  named.
- **A crash with a fallback mount open produces the system's "server connections
  interrupted" dialog.** The crash cannot be intercepted, only avoided by
  unmounting first.
- **Apple Silicon, macOS 15 or later, no Mac App Store.** Sandboxed apps cannot
  read raw devices or elevate.
- **TPM-sealed volumes and detached LUKS headers cannot be opened.**
