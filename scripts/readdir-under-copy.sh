#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# How long it takes to list the folder you are copying into.
#
#   ./scripts/readdir-under-copy.sh <image> [nr_requests]
#
# Measured through a thirteen-gigabyte Finder copy onto a real USB drive:
# listing the destination folder took 6 to 12 seconds, once past a 40-second
# timeout, while a folder nobody was writing to on the same volume answered in
# 20 milliseconds. Nothing was reported to the user and no request was ever
# declared unanswered -- it was simply slow, for as long as the copy ran.
#
# What it is not, both ruled out by measurement rather than argument:
#
#   not the nfsd thread pool   a starved pool cannot answer one directory in
#                              20 ms while another waits 7 s on the same mount
#   not the filesystem         NTFS on an SSD behaves like ext4 on an SSD;
#                              both are 0.02-0.03 s under continuous writes
#
# What is left is the device. On a drive absorbing about 7 MB/s the metadata
# reads for the directory being written have to reach the platter and queue
# behind the bulk write stream, while a quiet directory is answered from the
# guest's page cache and never goes near it.
#
# So the lever to try is the depth of that queue. The guest's block device runs
# mq-deadline already -- which is supposed to favour reads -- with
# nr_requests=256 and rotational=1, read_ahead_kb=128. mq-deadline can only
# reorder what it still holds; once requests are handed to a slow device they
# are gone. A shorter queue means fewer writes a read has to wait behind.
#
#   ./scripts/readdir-under-copy.sh drive.img 256    the shipped depth
#   ./scripts/readdir-under-copy.sh drive.img 32     a shorter queue
#
# THREE LEVERS TRIED ON THE REAL DRIVE. NONE OF THEM MOVED IT.
#
# Measured on the owner's BitLocker drive, 2 GB copied each time, the busy
# folder listed every two seconds throughout, every run byte-identical:
#
#   rdirplus, nr_requests=256 (shipped)  median 6.39s  worst 60.05s  4.6 MB/s
#   rdirplus, nr_requests=32             median 7.59s  worst 60.05s  5.4 MB/s
#   nordirplus, nr_requests=256          median 7.99s  worst 60.05s  6.0 MB/s
#
# The worst case is the sampler's own 60-second timeout in all three, so the
# tail is at least that and the medians are what separate them -- and they
# separate the wrong way. The shipped configuration is the best of the three
# on latency. Neither knob is the lever.
#
# With the earlier two, that is four explanations spent:
#
#   nfsd thread pool   no. A starved pool cannot answer a quiet directory in
#                      20 ms while the busy one waits seven seconds.
#   the filesystem     no. NTFS on an SSD behaves like ext4 on an SSD.
#   block queue depth  no. Shortening it made the median worse.
#   READDIRPLUS        no. Dropping the per-entry attribute fetch made the
#                      median worse too.
#
# AND IT IS NOT THE DEVICE EITHER. THAT WAS WRITTEN DOWN AND IT WAS WRONG.
#
# The device was blamed because NTFS on an SSD behaves like ext4 on an SSD, so
# the slow drive looked like the only variable left. One measurement kills it:
# during a copy, time a READDIR of the busy directory, a GETATTR of a single
# file *inside that same directory*, and a READDIR of a quiet one.
#
#   round   readdir-busy   stat-one-file   readdir-quiet
#       1        10.86s          0.02s          0.05s
#       2        90.06s          0.03s          2.81s
#       3         7.21s          0.03s          0.02s
#       6        90.05s          0.03s          0.02s
#       9         8.40s          0.03s          0.02s
#      10         4.15s          0.04s          0.02s
#
# Two of the listings ran past a ninety-second timeout. In the same seconds,
# asking the same drive for the size of a file *in the directory that was
# taking ninety seconds to list* was answered in thirty milliseconds, every
# single time.
#
# A saturated device cannot do that. If the platter were the queue, the GETATTR
# would wait in it too -- it reads an MFT record off the same disk behind the
# same writes. It does not wait. So the drive has spare capacity for metadata
# throughout, and the cost is in the READDIR itself: enumerating a directory
# whose index is being modified, not reaching the disk.
#
# Which is why none of the four knobs moved it. Thread count, filesystem,
# queue depth and READDIRPLUS are all about getting requests to the device
# faster, and the device was never the thing that was slow.
#
# THE DRIVER IS NOT IT EITHER, AND ntfs-3g IS WORSE
#
# If enumerating a modified directory is the cost, the driver walking that
# index is the next suspect. So the whole ladder was reversed to put ntfs-3g
# first and the same three columns measured on the same drive:
#
#   ntfs-3g   readdir-busy   stat-one-file   readdir-quiet
#         1         2.95s          0.02s          3.14s
#         3         3.69s          0.04s          7.45s
#         4        90.13s          0.03s          2.47s
#         5        90.04s          0.04s          3.20s
#         9        90.06s          0.03s          3.70s
#
# Three listings past the timeout instead of two, and worse than that: the
# quiet directory, which ntfs3 answers in 20 ms throughout, now takes two to
# seven seconds as well. ntfs-3g spreads the stall to directories nobody is
# touching. It is FUSE, so every operation crosses to a userspace process and
# back, and under a write stream that crossing is the queue.
#
# ntfs3 stays first. The stat column is 0.03s under both drivers, which is the
# same evidence twice over: the drive has metadata capacity to spare the whole
# time, and something above it will not use it for a READDIR.
#
# Throughput is reported beside latency on purpose. A shorter queue that halves
# the wait and halves the copy speed is not a win, and this goal will not take
# one number without the other.
set -uo pipefail
IMAGE="${1:-}"
NR="${2:-256}"
SECONDS_TO_RUN="${3:-180}"
[ -f "$IMAGE" ] || { echo "usage: $0 <image> [nr_requests] [seconds]" >&2; exit 2; }
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Dev.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
[ -x "$ENGINE" ] || { echo "error: no engine at $ENGINE" >&2; exit 2; }
APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
  "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo com.lukotta)"
export ANYLINUXFS_HOME="$HOME/Library/Application Support/$APP_ID/engine"
CFG="$ANYLINUXFS_HOME/.anylinuxfs/config.toml"
BASE="$(basename "$IMAGE" .img)"

WORK="$(mktemp -d)"
cleanup() {
  local v; v="$(where)"
  [ -n "$v" ] && umount -f "$v" >/dev/null 2>&1
  pkill -f "anylinuxfs mount.*$BASE" >/dev/null 2>&1
  /usr/bin/python3 - "$CFG" <<'PY' 2>/dev/null
import sys, pathlib, re

# Remove a custom action from config.toml, line by line.
#
# The obvious regex -- \[custom_actions\.NAME\][^\[]* -- is wrong, and it
# corrupted this machine's config repeatedly before anyone noticed. It stops at
# the first "[" it meets, and the line immediately below the header is
#     environment = ['NFS_SERVER_THREAD_COUNT=8']
# which contains one. So the header was removed and its body left behind, the
# file grew a stray orphan line on every run, and eventually the engine refused
# to parse it at all -- reporting "invalid table header", by which time several
# runs of results had already been taken through a broken config and believed.
#
# A section ends at the next line that STARTS with "[". That is the rule.
def drop_action(text, name):
    out, skipping = [], False
    for line in text.splitlines(keepends=True):
        if line.startswith("[custom_actions." + name + "]"):
            skipping = True
            continue
        if skipping and line.lstrip().startswith("[") and not line.lstrip().startswith("['"):
            skipping = False
        if not skipping:
            out.append(line)
    return "".join(out)
p = pathlib.Path(sys.argv[1])
if p.exists():
    s = p.read_text()
    s = drop_action(s, "lukottaqueue")
    p.write_text(s)
PY
  rm -rf "$WORK"
}
trap cleanup EXIT

where() {
  mount | awk -v w="$BASE-img.local:" '$1 ~ w {for(i=1;i<=NF;i++) if($i=="on") {print $(i+1); exit}}'
}

# The queue depth is set inside the guest before the mount, through the one
# channel into it that is not a patch. No `$VAR` anywhere: the engine reads
# every action for one and refuses the action if it finds it.
/usr/bin/python3 - "$CFG" "$NR" <<'PY'
import sys, pathlib, re
cfg, nr = sys.argv[1], sys.argv[2]
p = pathlib.Path(cfg)
s = p.read_text() if p.exists() else ""
s = drop_action(s, "lukottaqueue")
s += (
    "\n[custom_actions.lukottaqueue]\n"
    "description = 'Generated by readdir-under-copy.sh; sets the block queue depth'\n"
    "environment = ['NFS_SERVER_THREAD_COUNT=8']\n"
    "before_mount = 'modprobe nfsd > /dev/null 2>&1; "
    "mount -t nfsd nfsd /proc/fs/nfsd > /dev/null 2>&1; "
    "echo 131072 > /proc/fs/nfsd/max_block_size 2>/dev/null; "
    f"for q in /sys/block/*/queue; do echo {nr} > \"$q\"/nr_requests 2>/dev/null; done; "
    "head -n 1 /sys/block/*/queue/nr_requests 2>&1'\n"
)
# The engine refuses an action containing a shell variable, and the loop above
# needs one. Written with the glob expanded instead.
s = s.replace('for q in /sys/block/*/queue; do echo ' + nr + ' > "$q"/nr_requests 2>/dev/null; done; ',
              'echo ' + nr + ' > /sys/block/vda/queue/nr_requests 2>/dev/null; ')
p.write_text(s)
print(f"queue depth set to {nr}")
PY

pkill -f "anylinuxfs mount.*$BASE" >/dev/null 2>&1; sleep 3
nohup "$ENGINE" mount --ignore-permissions -w false -a lukottaqueue "$IMAGE" \
  > "$WORK/engine.log" 2>&1 < /dev/null &
for _ in $(seq 1 45); do [ -n "$(where)" ] && break; sleep 2; done
VOL="$(where)"
[ -n "$VOL" ] || { echo "error: never mounted; see $WORK/engine.log" >&2; exit 1; }
echo "mounted at $VOL"
grep -o 'nr_requests.*' "$WORK/engine.log" | head -2 | sed 's/^/  guest says: /'

rm -rf "$VOL/rd-busy" "$VOL/rd-quiet"
mkdir -p "$VOL/rd-busy" "$VOL/rd-quiet"
for i in $(seq 1 26); do head -c 4096 /dev/urandom > "$VOL/rd-quiet/q$i.bin"; done

SRC="$WORK/src"; mkdir -p "$SRC"
for i in $(seq 1 8); do head -c 33554432 /dev/urandom > "$SRC/big-$i.bin"; done

start=$(date +%s)
ditto "$SRC" "$VOL/rd-busy" >/dev/null 2>&1 &
copy=$!
sleep 3

busy_worst=0; busy_total=0; quiet_worst=0; quiet_total=0; n=0
end=$(( start + SECONDS_TO_RUN ))
while [ "$(date +%s)" -lt "$end" ]; do
  kill -0 "$copy" 2>/dev/null || break
  b0=$(/usr/bin/python3 -c 'import time;print(time.time())')
  timeout 60 /bin/ls -1 "$VOL/rd-busy" >/dev/null 2>&1
  b1=$(/usr/bin/python3 -c 'import time;print(time.time())')
  q0=$(/usr/bin/python3 -c 'import time;print(time.time())')
  timeout 60 /bin/ls -1 "$VOL/rd-quiet" >/dev/null 2>&1
  q1=$(/usr/bin/python3 -c 'import time;print(time.time())')
  b=$(/usr/bin/python3 -c "print(f'{($b1-$b0):.2f}')")
  q=$(/usr/bin/python3 -c "print(f'{($q1-$q0):.2f}')")
  n=$((n + 1))
  busy_total=$(/usr/bin/python3 -c "print(f'{$busy_total+$b:.2f}')")
  quiet_total=$(/usr/bin/python3 -c "print(f'{$quiet_total+$q:.2f}')")
  /usr/bin/python3 -c "import sys; sys.exit(0 if $b > $busy_worst else 1)" && busy_worst="$b"
  /usr/bin/python3 -c "import sys; sys.exit(0 if $q > $quiet_worst else 1)" && quiet_worst="$q"
  sleep 2
done
wait "$copy" 2>/dev/null
elapsed=$(( $(date +%s) - start ))
bytes=$(find "$VOL/rd-busy" -type f -exec stat -c %s {} \; 2>/dev/null | awk '{s+=$1} END{print s+0}')

printf 'nr_requests=%s  probes=%s\n' "$NR" "$n"
printf '  busy directory   worst %ss   mean %ss\n' "$busy_worst" \
  "$(/usr/bin/python3 -c "print(f'{$busy_total/max($n,1):.2f}')")"
printf '  quiet directory  worst %ss   mean %ss\n' "$quiet_worst" \
  "$(/usr/bin/python3 -c "print(f'{$quiet_total/max($n,1):.2f}')")"
printf '  copied %s bytes in %ss  (%s MB/s)\n' "$bytes" "$elapsed" \
  "$(/usr/bin/python3 -c "print(f'{$bytes/max($elapsed,1)/1048576:.1f}')")"
