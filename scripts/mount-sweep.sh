#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
# Measure one image under several engine configurations, one after another.
#
#   ./scripts/mount-sweep.sh <image> [file-count]
#
# The mount is the expensive part of every measurement here -- a microVM boots,
# a filesystem is found and mounted, an export is made -- so a sweep that takes
# the volume down and puts it back for each configuration is the only honest way
# to compare them. Nothing about a running mount can be changed underneath it.
#
# It leaves nothing behind: every mount it makes it takes away, and the engine's
# helpers with it. A helper left running holds the image file open and the next
# mount reports it as locked, which reads as a broken image rather than a stale
# process (see AGENTS.md).
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${1:-}"
COUNT="${2:-2000}"
[ -n "$IMG" ] && [ -f "$IMG" ] || { echo "usage: $0 <image> [file-count]" >&2; exit 1; }

ENGINE="${LUKOTTA_ENGINE:-$HERE/dist/Lukotta v2.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
[ -x "$ENGINE" ] || { echo "error: no engine at $ENGINE" >&2; exit 1; }

teardown() {
  local point
  for point in "$HOME"/Volumes/*; do
    [ -d "$point" ] || continue
    /sbin/mount | /usr/bin/grep -q " $point " && /sbin/umount -f "$point" >/dev/null 2>&1
    /bin/rmdir "$point" >/dev/null 2>&1
  done
  /usr/bin/pkill -f "Resources/engine/anylinuxfs" >/dev/null 2>&1
  /usr/bin/pkill -f "vmnet-helper" >/dev/null 2>&1
  /bin/sleep 2
}

# cores, ram MiB, net helper, offloading, label
run() {
  local cores="$1" ram="$2" helper="$3" offload="$4" label="$5"
  teardown
  "$ENGINE" config -n "$cores" -r "$ram" >/dev/null 2>&1
  local extra=()
  [ "$helper" = vmnet ] && extra+=(--vmnet-offloading "$offload")
  if ! "$ENGINE" mount --ignore-permissions -t ntfs3 --net-helper "$helper" \
      "${extra[@]}" -w false \
      --nfs-options=rsize=1048576,wsize=1048576,readahead=128 \
      "$IMG" >/dev/null 2>&1; then
    printf '%-34s  mount failed\n' "$label"
    return
  fi
  /bin/sleep 2
  local point
  point="$(/sbin/mount | /usr/bin/awk '/Volumes\// && /nfs/ {print $3; exit}')"
  if [ -z "$point" ]; then
    printf '%-34s  did not appear\n' "$label"
    return
  fi
  local out
  out="$("$HERE/scripts/volume-bench.sh" "$point" "$COUNT" 2>/dev/null)"
  printf '%-34s  %s\n' "$label" \
    "$(printf '%s' "$out" | /usr/bin/awk '
      /create/ {c=$4} /delete/ {d=$4} /write/ {w=$5} /read/ {r=$5}
      END {printf "create %6s ms  delete %6s ms  write %5s MB/s  read %5s MB/s", c, d, w, r}')"
}

printf 'sweeping %s, %s files each\n\n' "$(basename "$IMG")" "$COUNT"
run 1 512  vmnet   auto     "1 cpu / 512 MB  vmnet"
run 2 1024 vmnet   auto     "2 cpu / 1024 MB vmnet (the app)"
run 4 2048 vmnet   auto     "4 cpu / 2048 MB vmnet"
run 2 1024 vmnet   disabled "2 cpu / 1024 MB vmnet, no offload"
run 2 1024 gvproxy auto     "2 cpu / 1024 MB gvproxy (v1 before)"
teardown
printf '\ndone; nothing left mounted\n'
