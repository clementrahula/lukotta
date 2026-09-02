#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Does a heavy copy starve everything else talking to the same machine?
#
#   ./scripts/thread-starvation.sh <image> [threads] [seconds]
#
# One machine's nfsd threads are shared by everything talking to it, and a
# drive has more than one thing talking to it: Finder copying while Spotlight
# indexes the same volume, plus anything that stats it. Measured once by
# accident on a real drive -- a second, idle mount of a busy server went
# unanswered for fifteen unbroken minutes, and macOS declared it dead and took
# the volume away mid-copy:
#
#     kernel (nfs) nfs server ...: dead
#     diskarbitrationd removed disk, id = /Volumes/...
#
# So it is asked deliberately here, on an image, where the engine runs
# unelevated and the machine can be restarted as often as the question needs.
# A copy runs on one mount while a second mount of the same export is polled;
# what is counted is how long the quiet one waits, and whether it is ever left
# unanswered long enough to be evicted.
#
# Run it at the shipped thread count and again at a higher one. If the waits
# collapse, the count is the lever; if they do not, it is not, and the next
# place to look is the write path rather than the pool.
#
# TWO PROBES, BECAUSE THE FIRST ONE FLATTERED THE MOUNT
#
# The second-mount probe above answers "is another consumer starved". It does
# not answer the question a person asks, which is why the folder they are
# copying into takes ten seconds to list. So the loop now also times a READDIR
# of the directory being written, on the busy mount itself.
#
# That was added after watching a thirteen-gigabyte Finder copy onto a real
# drive through a sampler that was timing `stat` on the mount root -- the
# cheapest and most cached call available. It reported p50 0.027 s and p99
# 0.031 s across 2500 samples and looked like proof that nothing stalls. A
# listing of the busy directory on the same mount at the same moment took
# 10.891 s, then 9.168 s, and once ran past a 40-second timeout. A quiet
# directory elsewhere on the same volume took 1.88 s.
#
# Both numbers are true. Only one of them is about the user, and the mount root
# is not it.
#
# AND THE POOL IS NOT THE LEVER. MEASURED, NOT ASSUMED.
#
# The obvious reading of a ten-second listing is that eight nfsd threads are
# all sitting in megabyte writes and the READDIR is queued behind them. It is
# wrong, and one probe settles it: list the busy directory and a quiet
# directory on the same volume, alternately, in the same seconds.
#
#   round 1:  busy   0.32s    quiet   0.13s
#   round 2:  busy   6.98s    quiet   0.02s
#   round 3:  busy   6.73s    quiet   0.02s
#   round 4:  busy   3.43s    quiet   0.02s
#   round 5:  busy   3.26s    quiet   0.02s
#   round 6:  busy   4.33s    quiet   0.02s
#
# A starved pool cannot answer the quiet directory in twenty milliseconds while
# the busy one waits seven seconds. There is always a free thread. The
# contention is on the directory being written into, not on the machine.
#
# Which pointed at the filesystem rather than the export. NTFS keeps a file's
# size in its parent's index entry, so every write that extends a file touches
# the directory, and a READDIR wanting that directory waits on it. That was the
# theory. It is wrong, and the measurement that killed it is worth keeping.
#
# ext4 image, internal SSD, written to continuously for seventy seconds:
#   busy 0.04 0.05 0.02 0.03 0.02 0.04 0.02 0.03   quiet 0.02-0.03 throughout
#
# That looked like a confirmation until the confound was noticed: the ext4
# image is on an internal SSD and the NTFS volume is a USB drive delivering
# about 7 MB/s. Two variables had moved, not one. So NTFS was run on the same
# SSD, from a 64 MB image, under the same continuous write:
#   busy 0.03 0.02 0.03 0.03 0.02 0.03 0.02 0.02   quiet 0.02-0.03 throughout
#
# NTFS on a fast device behaves exactly like ext4 on a fast device. The
# filesystem is not the variable. The device is.
#
# NOTE, ADDED LATER: the conclusion below is wrong, and the correction is in
# readdir-under-copy.sh. It is not the device. During a copy a GETATTR of a
# file inside the directory that is taking ninety seconds to list is answered
# in thirty milliseconds, off the same drive, behind the same writes. A
# saturated device cannot do that. The cost is in enumerating a directory whose
# index is being modified, not in reaching the disk.
#
# So the mechanism is queueing, not locking: on a drive that absorbs 7 MB/s the
# metadata reads for the directory being written have to reach the platter and
# they queue behind the bulk write stream, while a directory nobody is touching
# is answered from the guest's page cache and never goes near the device. On an
# SSD the queue is too short to see.
#
# Which moves the next question inside the guest, to how that block device
# orders reads against a wall of writes -- an I/O scheduler question -- and not
# to the export, the thread pool, or the filesystem driver.
set -uo pipefail
IMAGE="${1:-}"
THREADS="${2:-8}"
SECONDS_TO_RUN="${3:-420}"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Dev.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
[ -f "$IMAGE" ] || { echo "usage: $0 <image> [threads] [seconds]" >&2; exit 2; }
[ -x "$ENGINE" ] || { echo "error: no engine at $ENGINE" >&2; exit 2; }

APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
  "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo com.lukotta)"
export ANYLINUXFS_HOME="$HOME/Library/Application Support/$APP_ID/engine"
CFG="$ANYLINUXFS_HOME/.anylinuxfs/config.toml"

WORK="$(mktemp -d)"; SECOND="$WORK/second"; mkdir -p "$SECOND"
cleanup() {
  umount -f "$SECOND" >/dev/null 2>&1
  pkill -f "anylinuxfs mount.*$(basename "$IMAGE")" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

# The thread count reaches the guest through the custom action's environment,
# which is the only channel into it that is not a patch.
python3 - "$CFG" "$THREADS" <<'PY'
import sys, re, pathlib
cfg, threads = sys.argv[1], sys.argv[2]
p = pathlib.Path(cfg)
s = p.read_text() if p.exists() else ""
s = re.sub(r"NFS_SERVER_THREAD_COUNT=\d+", "NFS_SERVER_THREAD_COUNT=" + threads, s)
p.write_text(s)
PY
echo "thread count set to $THREADS"

pkill -f "anylinuxfs mount" >/dev/null 2>&1; sleep 4
nohup "$ENGINE" mount --ignore-permissions -w false -a lukottatuned "$IMAGE" > "$WORK/engine.log" 2>&1 &
for _ in $(seq 1 40); do mount | grep -q ':/mnt/' && break; sleep 2; done
mount | grep -q ':/mnt/' || { echo "error: never mounted; see $WORK/engine.log" >&2; exit 1; }
BUSY="$(mount | awk '/:\/mnt\// {for(i=1;i<=NF;i++) if($i=="on") print $(i+1)}' | tail -1)"
echo "busy mount at $BUSY"

# A second mount of the same export: the quiet consumer.
mount -t nfs -o vers=3,port=2049,soft,intr,nolocks,dumbtimer,timeo=600,retrans=5,deadtimeout=900 \
  172.27.1.2:/mnt/"$(basename "$BUSY")" "$SECOND" 2>/dev/null \
  || mount -t nfs -o vers=3,port=2049,soft,intr,nolocks 172.27.1.2:/mnt/"$(basename "$BUSY")" "$SECOND" 2>/dev/null
mount | grep -q "$SECOND" || { echo "error: second mount failed" >&2; exit 1; }

# Something big enough to keep every thread busy for the whole window.
SRC="$WORK/src"; mkdir -p "$SRC"
for i in $(seq 1 6); do dd if=/dev/urandom of="$SRC/big-$i.bin" bs=1048576 count=60 status=none; done

ditto "$SRC" "$BUSY/starve-test" >/dev/null 2>&1 &
copy=$!

worst=0; total=0; n=0; evicted=no
rdworst=0; rdtotal=0; rdn=0
end=$(( $(date +%s) + SECONDS_TO_RUN ))
while [ "$(date +%s)" -lt "$end" ]; do
  kill -0 "$copy" 2>/dev/null || break
  t0=$(python3 -c 'import time;print(time.time())')
  timeout 60 stat "$SECOND" >/dev/null 2>&1 || evicted=yes
  t1=$(python3 -c 'import time;print(time.time())')
  w=$(python3 -c "print(f'{($t1-$t0):.2f}')")
  total=$(python3 -c "print(f'{$total+$w:.2f}')"); n=$((n+1))
  python3 -c "import sys; sys.exit(0 if $w > $worst else 1)" && worst="$w"

  # Listing the directory being copied into, on the busy mount itself. This is
  # the wait a person actually meets: the folder is open in Finder while the
  # copy runs, and every redraw of it is a READDIR queued behind the writes.
  #
  # It is measured here because the sampler watching a real thirteen-gigabyte
  # copy was timing `stat` on the mount root -- the cheapest, most cached call
  # there is -- and reported p99 0.031 s while a listing of the busy directory
  # on the same mount, at the same moment, took 10.891 s and then 9.168 s. The
  # quiet number was true and answered a question nobody had asked.
  r0=$(python3 -c 'import time;print(time.time())')
  timeout 60 /bin/ls -1 "$BUSY/starve-test" >/dev/null 2>&1
  r1=$(python3 -c 'import time;print(time.time())')
  rw=$(python3 -c "print(f'{($r1-$r0):.2f}')")
  rdtotal=$(python3 -c "print(f'{$rdtotal+$rw:.2f}')"); rdn=$((rdn+1))
  python3 -c "import sys; sys.exit(0 if $rw > $rdworst else 1)" && rdworst="$rw"
  sleep 2
done
kill -9 "$copy" 2>/dev/null; wait "$copy" 2>/dev/null

printf 'threads=%s  probes=%s  worst wait=%ss  mean=%ss  evicted=%s\n' \
  "$THREADS" "$n" "$worst" \
  "$(python3 -c "print(f'{$total/max($n,1):.2f}')")" "$evicted"
printf 'threads=%s  readdir on the busy directory: probes=%s  worst=%ss  mean=%ss\n' \
  "$THREADS" "$rdn" "$rdworst" \
  "$(python3 -c "print(f'{$rdtotal/max($rdn,1):.2f}')")"
