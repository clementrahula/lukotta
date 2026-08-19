# BitLocker Mounter 0.5

A small installerless macOS wrapper around two existing open-source projects:

- **anylinuxfs 0.19.0** — provides direct block-device access through a libkrun Linux microVM and exposes the mounted filesystem to macOS over localhost NFS.
- **anylinuxfs-gui 0.7.5** — the actual native Rust/Tauri macOS interface used after first-run setup.

This version deliberately contains **no JXA UI and no AppleScriptObjC UI**. The only AppleScript used by the outer launcher is standard macOS `display dialog` / `display notification` for first-run setup and fatal errors. The permanent drive interface is the upstream native GUI release.

## User flow

1. Launch `BitLocker Mounter.app`.
2. On first launch, the app downloads, checksum-verifies, privately installs, relocates and verifies every host/runtime component. Progress is surfaced while setup runs and the full raw log is written to Application Support.
3. `anylinuxfs init` completes before the disk UI opens, so the Linux guest, `cryptsetup`, NTFS tooling and NFS tooling are already present.
4. Before launching the disk UI, the wrapper forces the upstream GUI administrator-authentication policy to **Native**. It cannot inherit the optional Interactive Terminal mode from a previous anylinuxfs-gui preference.
5. The native disk UI opens and scans drives.
6. Select the BitLocker partition and mount it.
7. When the recovery-key dialog appears, paste the numerical BitLocker recovery password. The bridge accepts dashed, spaced, or undashed input and canonicalizes it to eight six-digit groups.
8. Before `cryptsetup` receives the key, the bridge verifies all eight BitLocker numerical-password blocks. Invalid input is rejected with a concrete error.
9. The bridge forces the **NTFS3** driver and `--ignore-permissions`. anylinuxfs then mounts read/write and opens the Finder mount unless the UI explicitly requested `ro`.

## What is private vs. system-wide

Nothing is installed to `/opt/homebrew`, `/usr/local`, `/Library`, or a kernel-extension location.

The app uses:

`~/Library/Application Support/BitLocker Mounter/`

for the native GUI copy, anylinuxfs runtime, private dylibs, bridge scripts, caches, and logs. anylinuxfs itself stores its initialized Linux root filesystem in `~/.anylinuxfs/`, matching upstream behavior.

## Pinned releases

- anylinuxfs-gui: **0.7.5**
  - release DMG SHA-256: `701118b5d04368a5153fa0f39d4fb78206509f409d6088797802efbab462fa3f`
- anylinuxfs: **0.19.0**
  - Tahoe arm64 bottle SHA-256: `2a0cb477920586660feda67197ebeeb05fa42621f0fb284bf4b15d1d071a0274`
  - Sequoia arm64 bottle SHA-256: `723586666ffae512c543546356678f30de45d341595b9028f4058969dfb32dac`

The dependency bottle hashes are pinned directly in `helpers/bootstrap.sh`. Downloads whose hashes do not match are rejected and never installed.

## Why the private CLI bridge exists

The native GUI already supports an `ANYLINUXFS_PATH` environment override. The launcher points it at `bridge/anylinuxfs`, so the GUI never needs Homebrew.

The bridge also provides the app-specific policy:

- BitLocker-candidate classification for generic `Microsoft Basic Data` partitions, so the native GUI requests the key before the privileged mount probe;

- recovery-password normalization and validation;
- NTFS3 instead of NTFS-3G compatibility mode;
- `--ignore-permissions` for Finder-friendly ownership;
- relocation/DYLD paths for the privately unpacked runtime.

The bridge is the exact CLI path that the upstream GUI later invokes through `sudo`, so validation also occurs at the privileged boundary rather than existing only as cosmetic front-end validation.

## Recovery-password validation

Microsoft describes the recovery password as 48 digits split into eight groups, with a checksum for each six-digit block. The validator removes spaces/hyphens, requires exactly 48 decimal digits, then checks each six-digit block before reformatting it as:

`xxxxxx-xxxxxx-xxxxxx-xxxxxx-xxxxxx-xxxxxx-xxxxxx-xxxxxx`

The validator rejects blocks outside the numerical-recovery-password range or not divisible by 11. The tests use the public example recovery password from the libbde BitLocker format documentation.

## Logs

- First-run setup: `~/Library/Application Support/BitLocker Mounter/logs/setup-v5.log`
- anylinuxfs initialization: `~/Library/Application Support/BitLocker Mounter/logs/anylinuxfs-init.log`
- Native GUI launcher output: `~/Library/Application Support/BitLocker Mounter/logs/native-gui.log`
- anylinuxfs runtime logs: upstream logs under `~/Library/Logs/`

Setup failures show the real reason returned by the setup script and offer the raw log instead of converting every error into a generic message.

## Tests

Run:

```bash
./tests/run-all.sh
```

The included tests cover:

- Bash syntax for every executable source file;
- absence of the removed JXA/AppleScriptObjC/fallback code paths;
- dashed, spaced, and undashed BitLocker recovery-password normalization;
- invalid length, characters, checksum, and out-of-range blocks;
- privileged CLI bridge argument rewriting and NTFS3 enforcement;
- duplicate/competing NTFS driver flag removal;
- end-to-end mocked first-launch sequence: setup -> readiness -> native GUI launch;
- propagation of `ANYLINUXFS_PATH` into the launched native GUI;
- forced `Native` administrator-authentication policy before each GUI launch;
- exact setup/native-launch error propagation to the user-facing error dialog.

The Linux build environment cannot execute a macOS Tauri binary, Hypervisor.framework, `hdiutil`, or a physical `/dev/disk*`. The permanent GUI is therefore not a hand-written UI claimed to be runtime-tested here; it is the upstream project's released macOS 0.7.5 build, which this wrapper downloads and verifies on the Mac before use.

## Rebuilding the wrapper bundle

`build.sh` needs no compiler. It reconstructs the outer `.app` from this source directory. The native GUI and anylinuxfs binary are deliberately acquired from pinned official releases on first launch rather than checked into this wrapper ZIP.

## Licenses

See `THIRD_PARTY_NOTICES.txt`. The wrapper source in this package may be used under GPL-3.0-or-later to remain compatible with the bundled/downloaded GPL components.
