# Measuring

## Finder Only, Headless

- A measurement of performance or stability counts only if Finder produced it: copy or delete speed, stalls, errors, skipped files, a lost mount.
- `dd`, `cp`, `ditto`, `rsync`, a test program and the engine's shell never produce one: not a quick look, not a proxy, not a baseline.
- Those tools make images, source files and fixtures, and check that what was written reads back identical. `finder-parity.sh` makes its source files with `dd`.
- Finder is driven by osascript with nobody clicking, as `scripts/finder-parity.sh` does. Nobody is asked to click, drag or watch.
- A number taken any other way is discarded: not quoted, compared, written down or used.

## The Drive the Faults Appear On

- Every timing measurement: a USB stick at 92% to 96% full. NTFS allocation slows as free space fragments.
- Numbers do not transfer to an empty drive. An empty drive is not evidence that a fault is gone.
- Sampled through a copy: idle in 119 of 178 one-second samples, p90 12 MB/s, peak 18 MB/s.
- A run removes what it wrote. Thirteen gigabytes twice does not fit, and ENOSPC reads like the fault under investigation.
- An experiment that varies the guest's configuration runs on an image. The real drive is for timing: an image on the internal disk is two orders of magnitude faster than the stick.

## Probes That Return a Plausible Wrong Number

A probe that cannot take a reading says so. Every call that can block is bounded. "Measured zero" and "could not measure" are different results.

| Probe | What it does | Instead |
| --- | --- | --- |
| `du -sm` on the destination | counts allocated blocks; climbed for minutes after a copy froze | sum `find -printf '%s'` |
| `find -printf '%s'` as liveness | stats the file being written and blocks on it | time `stat` on the directory |
| `nfsstat` on a wedged mount | blocks | bound it; its hang is the signal |
| `ls` where `ls` is `eza` | different columns; `awk '{print $5}'` sums zero | `find -printf` or `stat` |
| `grep -c` with no match | prints `0` and exits non-zero; `$(grep -c … \|\| echo 0)` prints two zeros | compare the printed count |
| `mount` first field against a share name | the field is `sweep-qcow2.local:/mnt/SWEEP` | literal prefix, `index($1, want) == 1` |
| `pgrep -f` in a waiting loop | matches the waiting shell's own command line | bracket (`'[s]napshots.sh'`), match the process (`pgrep -f 'bash \./scripts/run-tests\.sh'`), or wait on the pid |
| NFS unresponsive flag | never raised while a timed `stat` took 8.9 s | time the request |
| last line of the mount table | not this run's mount | the difference between before and after |
| `cmd \| sed` exit status | sed's status | `PIPESTATUS` |
| unquoted parameter in zsh | not word-split; twelve mounts are one iteration | read from a file, or split explicitly |
| a comparison on a full volume | reads as a data fault | check free space; clear what a stopped run left |
| `producer \| grep -q` under `pipefail` | SIGPIPE makes a match report failure | `grep -c` and compare, or read into a variable first |
| `stat` on the mount root | cached; p99 0.031 s while listing the busy directory took 10.891 s | list the busy directory |
| `readdir` | Finder uses `getattrlistbulk(2)`, slower here: median 8.42 s against 5.16 s | `scripts/bulk-list.c` |
| listing a quiet directory | answered from the client cache with no RPC | ask the server; 32 nfsd threads measured worse than 8 |
| `log show` | Lukotta's lines never appear on the development Mac, at any level, even unfiltered | `log stream`; `--drive sweep` in the foreground |
| a complaint counter at zero | same as a clean run | `watch-for-complaints.sh --probe` |
| `[ -w ]` | answers differently as root | create a file |
| a fixture's file name | `plain-xfs.img`: 2 GB long, 16 KB allocated, no superblock | `verify_image` in `make-format-volumes.sh` |
| a DEVTOOLS switch on a branded build | ignored silently | check the binary carries `--drive`; require positive output (`first-run-open.sh`) |
| `shasum` on a sparse image | reads the holes | `scripts/sparse-digest.py`: 1 TB image, 624 MB data, 0.4 s |
| a share looked for by one name | an image is served as `<name>-img.local`, a device as `diskN.local` | look for both |

## Guards and Harness Scripts

- A new guard is run both ways before it is trusted: given what it must catch, and what it must pass. `bash -n` and shellcheck prove parsing only.
- Guards that failed on first use: `strings | grep -q` under `pipefail`; a devtools check written the same way; a re-exec that computed the repository from its temporary copy's path; a mount wait that checked once where the engine route polls for eighty seconds.
- A guard written against a list of files checks the list, not the bundle.
- A running script's file is not edited. bash reads by byte offset and resumes mid-line; `bash -n` passes and the running copy dies. Edit a copy, or wait.

## Never Run Against a Real Disk

- **The plain-NTFS path.** The note that a drive is not encrypted, and opening one with no password. Identification is tested both ways over synthetic boot sectors; anything unrecognised is left alone.
- **The privileged route.** Every fixture is a container file, which opens unprivileged, so no harness has gone through `osascript` with an administrator password or through the daemon. The daemon's deadline, the script's own deadline and the daemon's unmount lent to the sweep are on that route. Their unprivileged twins run every time, and the shell the deadline is built from has its own test.
