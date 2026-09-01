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
nohup "$ENGINE" mount --ignore-permissions -a lukottatuned "$IMAGE" > "$WORK/engine.log" 2>&1 &
for _ in $(seq 1 40); do mount | grep -q 172.27 && break; sleep 2; done
mount | grep -q 172.27 || { echo "error: never mounted; see $WORK/engine.log" >&2; exit 1; }
BUSY="$(mount | awk '/172\.27/ {for(i=1;i<=NF;i++) if($i=="on") print $(i+1)}' | tail -1)"
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
end=$(( $(date +%s) + SECONDS_TO_RUN ))
while [ "$(date +%s)" -lt "$end" ]; do
  kill -0 "$copy" 2>/dev/null || break
  t0=$(python3 -c 'import time;print(time.time())')
  timeout 60 stat "$SECOND" >/dev/null 2>&1 || evicted=yes
  t1=$(python3 -c 'import time;print(time.time())')
  w=$(python3 -c "print(f'{($t1-$t0):.2f}')")
  total=$(python3 -c "print(f'{$total+$w:.2f}')"); n=$((n+1))
  python3 -c "import sys; sys.exit(0 if $w > $worst else 1)" && worst="$w"
  sleep 2
done
kill -9 "$copy" 2>/dev/null; wait "$copy" 2>/dev/null

printf 'threads=%s  probes=%s  worst wait=%ss  mean=%ss  evicted=%s\n' \
  "$THREADS" "$n" "$worst" \
  "$(python3 -c "print(f'{$total/max($n,1):.2f}')")" "$evicted"
