# The Engine at Run Time

## Exit Status and Diagnosis

- The engine exits 0 when a mount fails; the status describes its own shutdown. A mount is judged by the mount table: `MountScript.mountedCheck`.
- `mountedCheck` compares mount points by name against a baseline and looks for a new one. It does not count them: an NFS share the person mounted themselves, coming or going, moves a count.
- Failures are explained by text: `Diagnosis.rules`. Each rule records whether the words are the engine's or the Linux tooling's.
- `Diagnosis.enginesChecked` lists the engine versions the rules were tried against. Bumping `vendor/engine.lock` fails a test until the list is updated.
- The engine is driven through a pty by `expect`: strip `\r` before parsing or comparing.

## Helpers a Failed Mount Leaves

- `gvproxy` carries the network the NFS connection uses. The engine takes it down only when a mount it completed is ejected. A failed attempt leaves one holding the image file open, and the next attempt reports the file as locked.
- `Mounter` records the helpers running before an attempt and takes down those a failed attempt added.
- `EngineProcesses.tidyLeftovers` clears the rest at launch, only when the engine reports no mounts.
- Both match on the running bundle's own engine path; another copy of the app is left alone.

## The Mount Script

- `MountScript` lives in `LukottaCore`, which the privileged daemon links and runs.
- The generated script embeds a single-quoted `awk` program. An apostrophe anywhere in it, comments included, breaks the script. A test runs `sh -n` over the output.
- That program is `MountScript.volumeAction`, public so a test runs it with `awk -v s=… -v q="'" -v ro=…` over a listing. It is the only reader of the engine's volume list that decides what gets mounted.
- `rootfs.ver` is the engine's. It compiles its own copy in and compares it with the unpacked home on every mount. A home stamped otherwise re-initialises every time, takes `/tmp/anylinuxfs.lock` exclusive, and every drive after the first fails with "another instance is already running". A stale guest `vmproxy` does the same.
- This project's build number is in `rootfs.build`. `versionOfGuest` and `versionShipped` combine the two.

## Guest Actions in config.toml

- Generated as `before_mount = '…'`, a single-quoted TOML value.
- No single quotes inside: the engine reports a parse error at that line and mounts nothing. Double quotes are fine.
- No `$NAME`: the engine refuses to start on a shell variable it cannot resolve. Use backticks and repeat the command, as `ntfsRepair` does.
- A section ends at the next line that starts with `[`. `\[custom_actions\.NAME\][^\[]*` stops at `environment = ['…']`, deletes the header and orphans the body.
- Actions are merged into the existing file, so a section written by an older daemon can survive a reinstall. The engine's command line names the action it ran. Confirm a change from the guest's transcript line `Running before_mount action: ...`, not from the file.

## The Daemon

- Registered with `SMAppService`; runs from `Contents/MacOS/Lukotta<Brand>Helper` inside the app bundle. `/Library/PrivilegedHelperTools` holds daemons from the older install route and may be months stale.
- launchd keeps the running daemon across a rebuild, so a replaced bundle is still served by the old daemon's `MountScript`.
- `HelperProtocol.contract` is raised whenever the generated script changes. The build the daemon reports is also compared, so a rebuild replaces it.
- `--drive` waits for the daemon's pid to change and refuses to mount if it does not:

      the running daemon is older than this build; replacing it
      replaced; the daemon is now this build's

- Confirm from outside with `ps -eo pid,lstart` on the daemon before and after, or:

  ```bash
  before=$(pgrep -f 'LukottaDevHelper' | head -1)
  # … eject, open …
  after=$(pgrep -f 'LukottaDevHelper' | head -1)
  [ "$before" != "$after" ] || echo "stale daemon; the reading is worthless"
  ```

- The daemon cannot be killed from the user's account: `kill -TERM` does nothing, and `sudo` is not available non-interactively.
- The helper has no KeepAlive and never exits on its own. Replacing the app by hand leaves the old helper resident; `--reinstall-helper` takes it down and puts it back. Sparkle updates do not need it.
- `--check-helper [/dev/diskNsM]` exercises the reply and the error path against the real daemon. Without a device it probes the internal disk, which answers `unknown`: root cannot read the sealed system partitions.
- A channel without a daemon cannot mount, and harnesses then report faults in the app that are about the machine. The development Mac's `/Library/LaunchDaemons` holds the release and beta daemons only; a channel's first daemon needs a password. `scripts/dirty-ntfs-repair.sh` checks for the daemon first and names the channel.
- A real mount from a harness uses a `LUKOTTA_BRANDING=beta LUKOTTA_DEVTOOLS=1` bundle: `com.lukotta.beta.helper` is installed and replaces itself without a password, and devtools provides `--drive`.

## Opening a Real Drive Without a Person

DEVTOOLS builds only. Uses the saved Keychain key.

    "/Applications/Lukotta Dev.app/Contents/MacOS/Lukotta Dev" --drive open=/dev/disk4s1
    …                                                          --drive open=/dev/disk4s1 read-only
    …                                                          --drive eject=/dev/disk4s1
    …                                                          --drive identify
    …                                                          --drive sweep

- `identify` prints what the daemon reads from the first sector and whether the app offers the volume.
- `sweep` runs one sweep in the foreground and prints what it decided.

## The Engine Cannot Be Restarted on a Real Drive

- `/dev/diskNsM` is `root:operator` mode 640 and the account is not in `operator`. Started from a shell against a device, the engine answers `macOS: Error: Cannot probe /dev/diskNsM: LibErr(0); Insufficient permissions?`
- Changing `ram_size_mib`, the thread count or a `before_mount` action on a real drive means reopening it through the app (`--drive`).
- A container file opens unprivileged, and its machine can be restarted freely.

## Running the Engine From a Shell

- Without `ANYLINUXFS_HOME` it fails with `start vm error: Invalid argument (errno 22)`, with or without `sudo`. With it, the guest shell works unprivileged:

  ```bash
  export ANYLINUXFS_HOME="$HOME/Library/Application Support/com.lukotta/engine"
  dd if=/dev/zero of=big.img bs=1m count=0 seek=40960
  "$ENGINE" shell big.img -c "mkfs.ntfs -f -F -L BIG /dev/vda"
  ```

- `anylinuxfs shell` truncates an image to the last byte written: 320 MB in, 69 MB out. `scripts/e2e.sh` restores the length.
- `mkfs` in the guest discards the whole device first, and the image driver turns a discard into a shorter file:

  | Command | Image before | After |
  | --- | --- | --- |
  | `mkfs.ext4` on 1 GiB | 1,073,741,824 | 1,073,676,288 |
  | `mkfs.btrfs` on 1 GiB | 1,073,741,824 | 92,667,904 |

  Neither mounts afterwards (`open_ctree failed: -22` for btrfs). Restore the size after any `mkfs` in the guest:

  ```bash
  python3 -c "
  with open(path, 'r+b') as fh: fh.truncate(intended_size)"
  ```

- Ordinary writes and deletes, btrfs with `discard=async` included, leave an image its size.

## Ending Machines

- Never `pkill -9 -f 'anylinuxfs mount'`: it matches a machine serving a real drive. A create, remove or attribute change is answered before it is on the drive; on NTFS a kill leaves `$MFTMirr` behind `$MFT` and the volume read-only until repaired.
- Match the image under test, as `corrupt-corpus.sh` and `integrity-vectors.sh` do, and end machines with `SIGTERM`: 100 MB survives, and the machine exits in 0.34 s.
- `pkill -f 'corrupt-corpus'` matches its own command line. Use a bracket: `'corrupt-corpu[s]'`.

## NFS Mount Options

- The engine merges its defaults over `MountScript.nfsOptions` in a `BTreeMap` keyed by option name (`fsutil.rs` `NfsOptions::default`, `.extend` in `cmd_mount.rs`). The same key replaces the engine's value; a different key sits beside it.
- The engine adds `soft,intr,timeo=100,retrans=3`. The mount is soft.
- `hard` passed as well reaches the command, and mount_nfs takes the last of the pair: `soft,intr,nolocks,hard` by hand reports current parameters with `hard` and no `soft`. Ours land last.
- Soft is decided: it stops a kernel panic when a drive is pulled without unmounting. That claim is untested.
- `timeo` sets only the initial retransmit timeout. The dynamic estimator replaces it unless `dumbtimer` is set. Check `nfsstat -m` for `dumbtimer` before believing any timeout.
- `nfsstat -m`: "original mount options" is the request, "current mount parameters" is what is in force. `rsize`/`wsize` asked for at 1 MiB were granted at 128 KiB.
- The engine logs the exact mount command under `~/Library/Application Support/<bundle id>/engine/Library/Logs/anylinuxfs-*.log`.

### deadtimeout

- A drive that goes quiet stops answering NFS for longer than macOS waits. At the dead timeout the client unmounts, the engine sees its share go and shuts the machine down, and the copy ends. From outside it looks like a freeze.
- Removing the option is worse: a mount that loses its server never recovers.
- `MountScript` passes `deadtimeout=900`.
- Reproduction needs a volume large enough to build a dirty backlog in the guest: 40 GB NTFS, host disk saturated with a dozen `dd` writers. 64 MB and 252 MB volumes cannot reproduce it.

  | Setting | Result |
  | --- | --- |
  | `deadtimeout=45` | unmounted within 90 seconds, every run |
  | `deadtimeout=300` | mounted through ten minutes, still writing, full speed once the load lifted |

## Silence Is Not an Answer

- `EngineStatus.current()` returns an empty list when the engine could not be asked, could not run, exited non-zero or outlived its deadline. Use `currentIfAnswered()`, which returns nil for all four. Nothing destructive runs without an answer.
- `deadEngineMounts` needs a minute of silence and refuses while any microVM runs. A microVM frozen by a busy Mac was silent for forty seconds and came back serving its drive. `serving()` matches the `mount` process, not `gvproxy`.
- A mount point left after a mount vanishes is an ordinary directory on the startup disk, and a running copy writes into it. Those are reported, never swept; only empty ones are removed.

## vmnet

- NFS is served over gvproxy (user-space TCP/IP) or vmnet. vmnet measured two and a half times the write throughput.
- Every vmnet attempt ended with `Error connecting to port 2049: No route to host (os error 65)` and a healthy guest. Four causes, each sufficient:

  | Cause | Fact |
  | --- | --- |
  | Signing | `vmnet-helper` ships with `com.apple.security.virtualization`; re-signed without it, it fails with `VMNET_FAILURE`, prints nothing, and the engine reports an unparseable config. `init-rootfs` without entitlements fails with `start vm error: Invalid argument (errno 22)`. |
  | MAC address | vmnet assigns one; the engine gave the guest a random one. ARP is answered and the host learns a neighbour it cannot reach. |
  | Announcing | vmnet forwards only to a guest it has heard from. A silent guest's host ARP entry stays `(incomplete)`. |
  | Stale helpers | A leftover `vmnet-helper` keeps `bridge100` and its subnet; the next run routes to the old bridge. Kill every `anylinuxfs mount` and `libexec/vmnet-helper` and wait for the bridge to go between runs. |

- Ground truth, most decisive first:
  1. `/proc/net/snmp` in the guest: `Icmp: InEchos` and `Tcp: InSegs` say whether frames arrived.
  2. `ifconfig bridge100` (the MAC vmnet learned on `vmenet0`) against `arp -an` (the MAC the host sends to), in the same run.
  3. A socket client on the helper's socket answering ARP and ICMP, which takes libkrun out.
- `tcpdump` is unavailable: `/dev/bpf*` is root-only, and no password is asked for.

## Image Formats

- The drivers write VDI, VHD and VMDK flat and sparse. VHDX and stream-optimized VMDK are read-only.
- `krun-devices` marks the guest device read-only whenever the driver reports it cannot be written, so an unwritable image fails to mount writable rather than failing during a write.
- The write path is tested against `qemu-img` in `src/write_tests.rs`, carried by the imago patch: `cargo test` in the patched crate. The tests skip without qemu-img, so install qemu first.
- libkrun opens files an image names. A qcow2 naming a backing file or an external data file is refused before the engine is told: `Qcow2Header.namesAnotherFile`. A new format gets the same check ahead of the engine.

## Invariants

Changing one needs the evidence that established it.

- **A drive is open only where something is mounted.** The engine makes the mount point before mounting and leaves it after a failure. Only the mount table counts, on every route.
- **This app's own mounts are `.local:/mnt/…` or `.local:/run/…`.** A volume group is a tmpfs under `/run` with the volumes bound inside. An own AFP volume is served from `disk<N>.local` (`AfpShare.afpHost`). Recognising only the first shape would have let the sweep take down a machine serving a root and home.
- **The kept-aside copy is filed under the identifier.** `AppRollback.supportName` for the app; `bundle_identifier()` in `sources/LukottaLaunch/main.c` for the shim.
- **The copy is made when the archive arrives.** Sparkle sends `didDownloadUpdate` and `didExtractUpdate`, and does not send `willInstallUpdate`.
- **A copy of the running version is armed, not spent.** It is dropped only when it is of another version. Sparkle resumes an extracted update a session later without downloading it again. `--smoke-test` runs this path.
- **The machinery slipping is not the drive refusing.** A broken pipe, a locked image, an NFS mount macOS would not make: absorbed and retried, never reported. A wrong passphrase or an unreadable filesystem is reported at once. `TransientFailure` holds the list.
- **An attempt ends after eight minutes**, on every route, and what it started is taken down. The mount script ends itself sooner: ending a privileged attempt from outside reaches the shell, not the root engine under it.
- **A sweep takes down only what the app can show is its own**, and reports what really came down: a mount point it recorded when it made it, or one under the user's `~/Volumes`. A probe that could not start is not a mount that stopped answering.
- **A partition type is a claim; the first sector decides.** `VolumeKind.settled` takes the sector's answer in both directions. The daemon reads it (`HelperClient.identify`, 512 bytes a volume, cached per device).
- **A bundle run from anywhere but its installed path talks to its channel's installed helper.** Install it at its real path, or name the results the mismatched helper leaves unmeasured.
