# Lukotta code audit

A read of the whole tree at `main` (VERSION 1.14.0). The unit suite
(`./scripts/run-tests.sh`) passes 491/491, `./scripts/lint.sh` is clean, and
the snapshot and end-to-end suites were not run here (no built app; e2e is out
of bounds). Nothing tracked was modified.

## State of the codebase

This is a careful, unusually well-documented codebase. The hard lessons are
written down where they are needed (AGENTS.md, and dense "why" comments at every
sharp edge), the security invariants are stated and mostly held, the Swift-6
actor-isolation traps that killed build 232 are handled correctly and
deliberately, and the parsers for hostile image files are bounds-checked with
evident care. The unit suite is real and covers the pure logic well.

The weaknesses are almost all at the edges rather than in the core:

- A handful of **latent bugs that only bite on a different machine, a second
  user, a newer macOS, or a bumped engine** — the code assumes uid 501, a
  hard-coded minimum OS, an undocumented TCC schema, and the engine's exact
  output columns.
- A few **swallowed or short-circuited paths** — a case-typo that turns the
  formatter check into a no-op on a case-sensitive volume, a passphrase-redaction
  length guard that leaks very short secrets.
- **The most-advertised new feature (writing images) is the least proven** by
  the routine suite, and one read path (streamed VMDK) is effectively unproven.
- A couple of **release-path inconsistencies** around Sparkle deltas.

Severities below: critical / serious / moderate / minor. None reach critical;
the security-relevant ones are moderate and mostly already reasoned about in the
code.

---

## Findings by area

### 1. Build, lint, release, CI

**1.1 — moderate — `scripts/lint.sh:8`.** The swift-format step runs
`swift format lint --recursive --strict "$HERE/Sources"` with a capital `S`,
but the source directory is `sources` (lowercase, as AGENTS.md itself insists,
and as `Package.swift` requires). On the maintainer's case-insensitive APFS this
resolves and works; on a case-sensitive volume `swift format lint` is handed a
non-existent path and, as verified here, exits 0 with no output. The one check
that enforces house style silently lints nothing exactly on the filesystem the
project warns everyone about. shellcheck and coverage still run (they use the
lowercase relative path), so the script as a whole would still pass. *Fix:* use
`"$HERE/sources"`, and/or fail if the path does not exist before linting.

**1.2 — moderate — `sources/Info.plist:16` vs `BUILDING.md`.**
`LSMinimumSystemVersion` is hard-coded to `15.0`. BUILDING.md states "The lock
also decides the lowest macOS the finished app supports … `bottle_tag` sets the
floor". Nothing in `build-app.sh` derives the plist value from `bottle_tag`; it
is a static string, and only the *manual* `otool | grep minos` recipe in
BUILDING.md would reveal a mismatch. Ship an `arm64_tahoe` bottle (libblkid
minimum macOS 26) and the app still advertises 15.0 while the binary refuses to
load on 15–25. Today the shipped sequoia bottle happens to agree, so the bug is
dormant. *Fix:* set `LSMinimumSystemVersion` in `build-app.sh` from the lock's
`bottle_tag`, or assert the two agree at build time.

**1.3 — moderate — `scripts/release.sh:159–161`.** On the *first* release of a
version the `gh release create` branch (line 161) uploads only `$ZIP` and
`$SOURCES_ZIP` — not the `.delta` files. But if `LUKOTTA_PREVIOUS` pointed at
earlier archives, `appcast.py` was already given `--delta` entries whose URLs
are `$BASE_URL/…​.delta` on that same release. The appcast then advertises delta
enclosures that 404. Sparkle falls back to the full archive (so it is bandwidth,
not correctness, as the comment claims elsewhere), but it is still a wrong
appcast on a fresh release. Separately, the update branch (line 159) globs
`"$HERE"/dist/*.delta`; with no deltas present the glob stays literal and `gh`
errors. *Fix:* upload `dist/*.delta` in the create branch too, and guard the
glob (`shopt -s nullglob` or an existence test).

**1.4 — minor — `scripts/appcast.py:88–96`.** Delta `<enclosure>` elements carry
`sparkle:deltaFrom` and `sparkle:edSignature` but no `sparkle:version` /
`sparkle:shortVersionString`. Depending on the Sparkle version this can be
tolerated (the item's version is used), but it is worth confirming against the
Sparkle release in `Package.resolved` that delta selection does not need the
per-enclosure version. Unverified here.

**1.5 — minor — `.github/workflows/engine-updates.yml:21,41`.** `audit.yml`
pins its third-party scanner actions to commit SHAs on purpose (commit "Pin the
scanners to commits, not tags"), but `engine-updates.yml` still uses
`actions/checkout@v4` and `actions/github-script@v7` as moving tags. These are
first-party GitHub actions so the risk is lower, but the same supply-chain
argument applies; the pinning policy is applied inconsistently.

**1.6 — minor — `build-app.sh:56`.** The version guard
`case "$VERSION" in [0-9]*.[0-9]*.[0-9]*)` is a lenient shell glob (`*` matches
any characters), so `1x.2.3` or `1..` would pass. `VERSION` is produced by
`bump-version.sh`, so impact is low; a stricter check (`grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'`)
would be cheap.

### 2. Privileged helper and XPC surface

**2.1 — moderate — `sources/LukottaHelper/main.swift:247,256`.** `invokingUID()`
and `invokingGID()` fall back to hard-coded `501` / `20` when
`SCDynamicStoreCopyConsoleUser` returns 0 (no console user: loginwindow, fast
user switching mid-transition, an SSH session, screen locked in some states).
The helper then composes a mount script that exports `SUDO_UID=501`/`SUDO_GID=20`
and resolves the engine's home/config against uid 501. On a Mac whose primary
account is not 501, or for a second user, this silently targets the wrong user's
`~/.anylinuxfs` and `config.toml`. This is the concrete "second user" failure.
*Fix:* prefer the XPC peer's audit-token euid (the peer is the app the real user
is running), or refuse the mount when no console user can be determined rather
than guessing 501.

**2.2 — moderate (known, accepted) — `sources/LukottaHelper/main.swift:57–71`.**
Client verification identifies the peer by `connection.processIdentifier` and
`SecCodeCopyGuestWithAttributes`. The code documents that the audit token would
be immune to pid reuse but is private API, and that the reuse window is tiny.
This is a reasonable trade-off and correctly bounded, but it remains the single
client-verification weakness: if `NSXPCConnection.auditToken` ever becomes
public, switch to it. No change needed now; flagged so it is not forgotten.

**2.3 — minor — `sources/LukottaHelper/main.swift:266`.** `invokingHome()`
returns `/Users/Shared` when `getpwuid` fails; a `config.toml` written there is
one the engine (resolving against `SUDO_UID`) never reads. It is a silent
misdirection rather than an error. Coupled with 2.1, the wrong-uid path can
produce a config the engine ignores.

**2.4 — good.** The FIFO credential path, the "parameters never a command"
protocol, and the by-value redaction of the reply are all as SECURITY.md
describes. The two-selector versioning of `mount(...)` (old read-write selector
kept so a stale helper still answers) is handled correctly on both sides
(`HelperClient.mount` falls back only for read-write, and refuses to silently
mount writable when read-only was asked of an old helper).

### 3. MountScript (generated shell)

**3.1 — moderate — `sources/LukottaCore/Diagnostics.swift:123`.**
`redact(_:secret:)` only removes the secret by value when
`trimmed.count >= 4`. A LUKS passphrase of 1–3 characters is legal, and because
the engine is driven through a pty that echoes input, such a passphrase can come
back in the transcript that reaches the screen, the workspace log, and a bug
report. The length guard exists to stop a short secret over-matching ordinary
output, but an exact-value replacement of the whole secret cannot over-match
anything but itself. *Fix:* redact any non-empty secret by value; drop or lower
the length guard (or apply it only to the shape-based patterns, not the
by-value pass).

**3.2 — minor/robustness — `sources/LukottaCore/MountScript.swift:274` and the
`mountedCheck`.** Success is proved solely by counting lines of
`/sbin/mount | grep -cE ':/(mnt|run)/'` and comparing against a baseline. If the
user (or a second copy of anylinuxfs) has any NFS mount whose server path
contains `/mnt/` or `/run/`, the baseline is polluted and a genuine mount can be
counted as a failure, or a residual one as a success. The `exportName` character
set and the `/run` scratch dir keep Lukotta's own mounts well-formed, but the
count is global, not scoped to this attempt's export name. Low likelihood, high
consequence (this is the only signal that a mount worked, since the engine exits
0 regardless).

**3.3 — moderate — `sources/LukottaCore/VolumeGroups.swift` and the multi-volume
`awk` in `MountScript.swift:multiVolume`.** Both parse the engine's
`list --decrypt` output by fixed column position: index, type, optional
name…, size *value*, size *unit*, identifier — i.e. they assume the size is two
whitespace-separated tokens and the identifier is last. A reformat upstream
(a single-token size like `608MB`, a localised unit, an extra column) shifts
every field: the NAME reconstruction (`for f = 3; f <= NF-3`) and the filesystem
detection break silently, and a multi-volume container mounts wrong or not at
all. This is the same fragility class that `Diagnosis.enginesChecked` guards for
failure phrases, but this parser has **no** version-pinned test. *Fix:* add a
captured-fixture test tied to `enginesChecked`, or anchor parsing on the
`vg:disk:lv` identifier and the type rather than on offsets from the end.

**3.4 — good.** Quoting (`shellQuoted`, `appleScriptQuoted`), the single-quoted
`awk` apostrophe hazard, the `-n`/`--decrypt`/`--nfs-options` variadic-flag
traps, the read-only retry grouping (`{ … && echo }`), and the CRLF strip after
`expect` are all correct and tested. `sh -n` over the generated script is run in
the suite.

### 4. Image-format parsers (Swift)

**4.1 — good.** `Qcow2Header`, `VdiHeader`, `VhdFooter`, `VhdxHeader`,
`SparseVmdkHeader`, `VmdkDescriptor` all bounds-check before every fixed-width
read; `be*/le*` helpers slice after a length check; `hasExternalDataExtension`
walks extensions with an `offset + 8 <= count` guard; `metadataAt` caps the
region count; `namesAParent` checks `offset + 8` before reading; the qcow2 check
tests *both* the feature bit and the header extension for an external data file,
and refuses corrupt images. The "names another file" invariant is enforced in
this layer as SPECS claims. No overflow or out-of-bounds read was found.

**4.2 — minor — `sources/LukottaCore/Vmdk.swift`, `parseExtent`.** A non-`ZERO`
extent line without a quoted filename yields `filename == nil`, which
`namesAFileElsewhere` maps to `false` and the "every extent must be present"
loop skips (`guard let name … else { continue }`). A malformed FLAT extent with
no quotes therefore passes every objection and is handed to the engine. VMware
always quotes, so this is hostile-only and low severity, but a FLAT/RW extent
with no filename should be rejected rather than ignored.

**4.3 — low/observation — `Vmdk.swift`, `reachesElsewhere`.** Extent names are
rejected for `/`, `\`, `..`, absolute paths and empties, but a plain name that
happens to be a symlink sitting beside the descriptor is followed. Reach is
bounded to files the user could already read (images open unprivileged), so this
is within the stated threat model; noting it because it defeats the "beside the
descriptor" intent.

### 5. Rust write paths and krun-devices (patches)

**5.1 — moderate / needs verification — `patches/imago-vdi-vhd-and-vhdx.patch`,
VDI `ensure_data_mapping` (~L554–577), and the analogous VHD/VMDK paths.** The
allocation order is: `resize` (grow file) → `flush` → write allocated-count →
`flush` → write map entry → `flush`. The reasoning (interrupt leaves an orphan
block the next writer skips; the reader sees the map entry still free and reads
zeroes) is sound **against a process crash**. It is only sound against **power
loss** if `Storage::flush()` is a durability barrier (fdatasync / write barrier)
rather than a userspace buffer flush. SPECS §6 makes the stronger "crash
consistency" claim ("a writer interrupted part-way leaves a file the next reader
can repair"). Confirm what imago's `flush()` maps to on macOS; if it is not a
durable barrier, either use `sync()` at the ordering points or soften the SPECS
claim to process-crash consistency.

**5.2 — moderate — `patches/krun-devices-image-formats.patch`.** The VMDK arm
has a fallback: if opening for write returns `ErrorKind::Unsupported`, the file
is reopened read-only (`read_only_opts`) and the guest device is marked
read-only. VDI and VHD (and qcow2/raw) have **no** such fallback — they call
`open_image_sync(file, !is_disk_read_only)` and propagate any error. A
write-requested VDI/VHD on a read-only medium, or one the driver decides it
cannot write, fails the whole mount instead of degrading to read-only. The
recomputed `is_disk_read_only = is_disk_read_only || !disk_image.inner().writable()`
that follows only helps once the open has succeeded. *Fix:* give VDI/VHD the
same `Unsupported → reopen read-only` path as VMDK, or confirm those drivers
never return `Unsupported` from `open_image_sync`.

**5.3 — minor — same patch.** The recomputed `let is_disk_read_only = …`
*shadows* the earlier binding immediately before `disk_properties` is built.
Correctness depends on `disk_properties` (and whatever tells the guest the device
is read-only) consuming the shadow, not a value captured earlier. It reads
correctly in the diff fragment, but should be confirmed against the full
generated `device.rs`, since a use of the pre-shadow value would silently
present a read-only device as writable.

### 6. Concurrency and lifecycle

**6.1 — minor — `sources/Lukotta/AppModel.swift:762,1296`;
`sources/LukottaCore/Mounter.swift:163`.** A drive is matched to its mount by
`key.contains(drive.id)` / `devicePath.contains(drive.id)`. `drive.id` is
`diskNsM`, and `"disk4s1"` is a substring of `"disk4s10"`, so a disk with more
than nine partitions (or two disks whose ids nest) can match the wrong mount:
the row reports the wrong open state, or eject/`dropMounts` filters the wrong
entry. *Fix:* match on a delimiter boundary (e.g. `":" + id`, or the full
`lvm:vg:disk:lv` triple) rather than a bare substring.

**6.2 — low — `AppModel.runMount…` / `workspace`.** `self.workspace` is
overwritten on each mount, while the previous mount's detached task may still
hold the earlier `Workspace`; `cleanUp()`/quit destroys only the current one.
In practice one `mountTask` runs at a time, so this is a latent rather than
active bug.

**6.3 — good.** The nonisolated-closure discipline for Objective-C callbacks
(`HelperClient.roundTrip`, `ResumeOnce`, `moveToTheBin`, `ResumeOnceMessage`) is
correct and the reason is documented. `--check-helper` exercises both the reply
and the error path against the real daemon. `EngineProcesses` scoping to the
running bundle's own engine path is right. Sleep/wake handling stops the
free-space poll before sleep and probes mounts out-of-process (`MountProbe` via
`df` with a kill-on-timeout), which avoids the wedged-`statfs` trap.

### 7. Permissions detection

**7.1 — moderate — `sources/LukottaCore/Engine.swift:353`.**
`hasFullDiskAccess` returns `true` when neither `TCC.db` nor `CloudTabs.db`
exists to probe ("do not block on a guess"). On an account where both are
absent, FDA is reported granted, the permission screen is skipped, and the first
mount fails with an access-denied transcript that `isAccessDenied` then catches
to flip to `needsPermission`. The stated promise — "say so before a password is
typed" — is therefore not always kept; the user can see a failed attempt first.
Acceptable degradation, but worth knowing the up-front detection has a
false-positive path.

**7.2 — minor/brittleness — `Engine.swift`, `removableVolumeAccess()`.** Reads
the TCC `access` table directly (`service = kTCCServiceSystemPolicyRemovableVolumes`,
`auth_value == 2`). This is an undocumented schema; a macOS release that renames
the column or changes the auth encoding makes it return `nil` (falling back to
`DriveMemory.hasAny`). Graceful, but the "removable volumes granted" banner can
go stale or wrong across an OS bump.

### 8. UI and localisation

**8.1 — minor — `sources/Lukotta/AppModel.swift:1503–1508`.** `noteVolumeCount`
fires whenever `totalCount > opened`, which includes `total = 1, opened = 0`
(a single-volume LVM container whose one volume failed to open: the script emits
`LUKOTTA_VOLUMES:0:1`). The message "This drive holds `%lld` volumes and not all
of them could be opened" has **no** plural variation for that string (only the
standalone `"%lld volumes"` does), so it renders "…holds 1 volumes…"
ungrammatically in English and every translation. *Fix:* guard the notice to
`totalCount >= 2`, or add plural variations to that string.

**8.2 — good.** The count strings that can legitimately be 1
(`"%lld open drives will be ejected"`, `"%lld drives had stopped responding…"`,
`"Quit and leave %lld drives open?"`, `"Also delete %lld saved passphrases…"`)
all carry plural variations in `Localizable.xcstrings`, and two-count sentences
are deliberately avoided (documented). Accessibility labels are present on the
credential field, the reveal toggle, the permission rows and the disclosure. 21
languages are complete against 299 strings (verified by `check-coverage.sh`).

---

## Brittleness: works now, breaks on a change of circumstance

- **A case-sensitive volume** turns the swift-format lint into a silent no-op
  (1.1).
- **A bumped `bottle_tag`** makes the app claim macOS 15 while requiring more
  (1.2).
- **A second user, or a first user not uid 501**, misdirects the helper's engine
  home/config (2.1/2.3).
- **A newer macOS** can break the TCC schema read and stale the removable-volumes
  banner (7.2); the FDA probe files may be absent on a fresh account (7.1).
- **A bumped engine that rewords or reformats `list --decrypt`** breaks LVM
  parsing with no guarding test (3.3); the failure-phrase rules are guarded
  (`Diagnosis.enginesChecked`), the column layout is not.
- **A user's own NFS mount under `/mnt` or `/run`** perturbs the success count
  (3.2).
- **A disk with >9 partitions** (or nested disk ids) can mis-match a mount by
  substring (6.1).
- **A second/first release with previous archives present** advertises delta
  URLs that were never uploaded (1.3).
- **A rebuild without an intervening commit** reuses the build number, so two
  different binaries claim the same build (documented in AGENTS.md; still a real
  hazard for the rollback record, which keys on `CFBundleVersion`).
- **A very short passphrase** can survive redaction into logs/reports (3.1).
- **A slower drive / slow resume** is covered by `WakeRecovery.grace = 60s`;
  a drive that legitimately takes longer than a minute to answer after wake is
  declared dead and dropped.

---

## Claimed but not proven by any test

- **Writing to qcow2 / VMDK / VDI / VHD.** SPECS §6 says the write paths are
  "checked against `qemu-img` on every build". They are not: the Rust
  `write_tests.rs` skip when `qemu-img` is absent (SPECS itself admits "a green
  run without it proves nothing"), and neither `run-tests.sh` nor CI builds the
  engine or runs `cargo test` on the patched crate. The only real proofs are
  (a) a manual `cargo test` with qemu installed and (b) `scripts/e2e.sh`'s
  `writeFlow` on a real Mac — neither in the default path or CI. README's
  "untested" wording is honest; SPECS' "on every build" overstates.
- **Streamed VMDK read.** `EndToEnd.swift` opens `streamed.vmdk` only
  `if FileManager.default.fileExists`, with no failing `else`, and e2e never
  generates one (only qemu-img writes it). So the streamed read path is
  effectively unproven, yet `check-coverage.sh` reports it covered because it
  merely greps for the literal string `streamed.vmdk` in `e2e.sh`, which a
  comment satisfies.
- **A clean VHDX actually mounting and reading correct bytes.** The objection
  tests cover refusal (dirty log, named parent); a good VHDX reading back
  correctly is only in e2e.
- **The privileged helper's `SecCode` client check, the FIFO hand-off, and
  redaction under a real pty.** `clientRequirement` string construction is unit
  tested, but the actual `SecCodeCheckValidity` gate cannot be (no signed peer
  in the test binary), and the pty-echo redaction is only reasoned about.
- **Multi-user / non-501 behaviour** (2.1) — untested and, as noted, likely
  wrong.
- **Snapshot rendering** — verified only on the machine that recorded the
  baselines; CI cannot and does not compare them.
- **Sleep/wake recovery, DiskArbitration claiming, eject-during-mount,
  unplug-mid-flight, permission-revoked-mid-flight** — the logic exists and
  `WakeRecovery.nextDelay` is unit tested, but the integration paths are proven
  only by hand.
- **LVM column parsing** (3.3) — no version-pinned guard, unlike the failure
  rules.

---

## Prioritised work list

1. **Redact short secrets (3.1, `Diagnostics.swift:123`).** Security-relevant
   and a one-line change: a 1–3 character passphrase can reach a bug report.
   Drop the length guard from the by-value pass.
2. **Fix the helper's uid/gid fallback (2.1, `LukottaHelper/main.swift:247`).**
   The concrete "second user / not-501" failure; derive the user from the XPC
   peer or refuse rather than guess 501.
3. **Fix the lint case-typo (1.1, `lint.sh:8`).** The style gate is silently off
   on case-sensitive volumes; trivial fix, and it is the exact trap the project
   documents.
4. **Verify `flush` vs durability in the write paths (5.1) and add the VDI/VHD
   read-only fallback (5.2).** These decide whether the write feature's central
   safety claim (crash consistency) and its degradation story actually hold.
   High value because writing is the newest, least-proven, most dangerous
   capability.
5. **Derive `LSMinimumSystemVersion` from the lock (1.2).** Prevents shipping an
   app that lies about the OS it runs on the day a different bottle is pinned.
6. **Add a version-pinned test for the LVM `list --decrypt` column parser
   (3.3).** Bring it under the same discipline as `Diagnosis.enginesChecked` so
   an engine bump cannot silently break multi-volume mounts.
7. **Make streamed-VMDK coverage real (claimed-but-not-proven).** Either commit
   a small streamed fixture, or make `check-coverage.sh` assert a genuine open
   rather than grep for a string, so the gap is visible.
8. **Fix the release delta upload/advertise mismatch (1.3) and guard the glob.**
   Prevents a fresh release from shipping an appcast that points at missing
   deltas.
9. **Replace substring drive-id matching with a delimiter match (6.1).** Cheap
   correctness fix for disks with many partitions.
10. **Guard the "N volumes" notice to N≥2 (8.1)** and tidy the smaller items
    (2.3, 4.2, 1.5, 1.6, 7.2).

---

## What was done about it

Worked through in the order the list above sets out. Every entry names the
commit that closed it. The unit checks went from 495 to 545, and each fix that
could be tested brought its own.

### Build, lint, release, CI

- **1.1 lint linted nothing** — `a6e9a86`. `sources`, lowercase, and the script
  now fails if the directory is not there rather than linting an empty set.
- **1.2 the plist promised macOS 15 regardless** — `c683606`.
  `scripts/lowest-macos.py` reads the floor from the engine's bottle,
  `build-app.sh` writes it into `LSMinimumSystemVersion`, and the built binary's
  own `minos` is compared with it. Disagreement fails the build.
- **1.3 deltas advertised and not uploaded** — `8dabe8e`. Both branches of the
  release upload exactly the deltas the appcast names, taken from the list built
  above rather than from a glob that could match an earlier run's leftovers or
  stay literal.
- **1.4 delta enclosures carry no version** — checked, nothing to change, and the
  reason is now in `appcast.py`: Sparkle builds each delta item from a copy of
  the item, so it inherits `<sparkle:version>`. Read in Sparkle 2.9.6, which is
  what `Package.resolved` pins.
- **1.5 actions pinned inconsistently** — `b320901`. All of them carry a commit
  with the version in a comment, and `lint.sh` fails on any `uses:` that is not
  a forty-character commit, so it cannot drift back.
- **1.6 the version glob accepted "1x.2.3"** — `c683606`, alongside 1.2.

### Privileged helper

- **2.1 / 2.3 uid 501 guessed, `/Users/Shared` invented** — `de1c3ba`. The user
  comes from the XPC peer, with the console user as a second opinion; where
  neither answers, or the home cannot be resolved, the mount is refused instead
  of being pointed somewhere arbitrary.
- **2.2 pid-based client verification** — left as the audit found it. The audit
  agrees it is correctly bounded; it changes when `NSXPCConnection.auditToken`
  becomes public API.

### The generated script

- **3.1 a short passphrase survived redaction** — `a6e9a86`. Any non-empty
  secret is removed by value; a test covers one, two and three characters.
- **3.2 success proved by counting everything** — `3ccb5d0`. The script lists
  the engine's mount points by name and looks for one that was not there before,
  which somebody else's NFS share cannot move.
- **3.3 the volume listing parsed by counting from the end** — `d2b1c32`. Both
  readers find the size by its unit instead. The awk is now
  `MountScript.volumeAction`, public so a test can run it: it and the Swift
  parser are checked against the same captured listing, including a one-field
  size and a label of several words.

### Image parsers

- **4.1** — nothing to fix; the audit found the bounds checks sound.
- **4.2 an extent naming no file** — `01796c0`. Refused rather than skipped.
- **4.3 a name that is a symlink out of the folder** — `01796c0`. Extents are
  resolved and must still be beside the descriptor.

### The write paths

- **5.1 what an interrupted write survives** — `6bc1649`. The audit was right:
  imago's `flush()` is std's, which for a plain file is not a barrier. SPECS now
  says what holds — ordering against a writer that stops — and where durability
  across a power cut actually comes from: the guest's own barriers, which reach
  the device as flush requests and are answered with a sync.
- **5.2 no read-only fallback outside VMDK** — `d01cef9`. A file that will not
  open for writing is opened for reading, and the guest is told the device is
  read-only. VDI and VHD also take the Unsupported → read-only path.
- **5.3 the shadowed `is_disk_read_only`** — confirmed correct in the generated
  `device.rs`: the shadow is what sets `VIRTIO_BLK_F_RO`, and `is_read_only()`
  reads that feature bit.

### Concurrency and lifecycle

- **6.1 disk4s1 matching disk4s10** — `192a45a`. `Drive.owns()` refuses a match a
  digit follows, so a whole disk still owns its partitions and no partition owns
  another.
- **6.2 workspaces left behind** — `0e7f2c6`. Every workspace this session made
  is removed on quit, not only the last.
- **6.3** — nothing to fix.

### Permissions

- **7.1 nothing to probe read as granted** — `4b22b75`. The system's own TCC
  database is probed as well, and it is there on every install.
- **7.2 the TCC schema read blind** — `4b22b75`. The columns are checked first;
  an unexpected shape reads as not knowing, and says so in the log.

### Interface

- **8.1 "this drive holds 1 volumes"** — `cad5182`. The notice needs two or more,
  and the parsing moved to where a test can reach it.
- **8.2** — nothing to fix.

### Claimed but not proven

- **Streamed VMDK** — `57ebb50`. `scripts/make-vmdk-streamed.py` writes one, so
  the end-to-end run has one on any Mac. qemu-img converts what it writes back
  to the original raw image byte for byte, and the driver reads it back byte for
  byte. The end-to-end run now fails on a fixture it was handed that is not
  there, rather than skipping the flow and finishing green, and the coverage gate
  asks that each format reach the run rather than merely appear in the file.
- **"Checked against qemu-img on every build"** — `57ebb50`. README now says
  when it happens: building the engine from source.
- **A rebuild reusing the previous build number** — `dafcbf0`. The build says so
  when the tree is dirty.

### Still open, deliberately

- The helper's `SecCodeCheckValidity` gate, the FIFO hand-off and redaction under
  a real pty cannot be exercised from the test binary: there is no signed peer in
  it. Unchanged, and the reasoning is in SECURITY.md.
- Snapshots are compared where they were recorded. A hosted runner draws every
  screen differently, so comparing there would fail on all of them and mean
  nothing.
- Sleep and wake, DiskArbitration claiming, eject during a mount, unplug
  mid-flight: the logic is unit tested where it can be, and the integration paths
  are still proven by hand.
- `WakeRecovery.grace` stays at sixty seconds. A drive slower than that after a
  wake is declared gone; raising it makes every genuinely dead mount take longer
  to clear.
