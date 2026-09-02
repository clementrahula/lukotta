#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Write the corpus into every image format the app says it can write to, and
# read every byte back.
#
#     ./scripts/format-write-sweep.sh [size-mib]
#
# The end-to-end run opens each of these formats and ejects it, which proves
# the driver reads. It does not write to any of them, and the app advertises
# writing to qcow2, VDI, VHD and both flat and sparse VMDK. Those drivers were
# written for this project, checked against qemu-img, and never had a corpus
# through them, so "if the app claims it, it is tested" was not true of the
# half that matters most.
#
# Each format gets a fresh image of its own, formatted NTFS by the guest,
# opened through the engine, and put through scripts/copy-torture.sh. Streamed
# VMDK and VHDX are read-only by design and are not in the list; a fixed VHD is,
# because it is written like any raw disk.
set -u

MIB="${1:-2048}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP="${LUKOTTA_APP:-/Applications/Lukotta Dev.app}"
ENGINE="${LUKOTTA_ENGINE:-$APP/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
[ -x "$ENGINE" ] || { echo "no engine at $ENGINE"; exit 1; }

# The app's own engine home. vm_image::init wants an exclusive flock when the
# rootfs it is given needs unpacking, and cannot have one while the app holds
# shared locks for drives already open.
export ANYLINUXFS_HOME="${ANYLINUXFS_HOME:-$HOME/Library/Application Support/com.lukotta.dev/engine}"

WORK="${LUKOTTA_SWEEP_DIR:-$HOME/.lukotta-testvols/sweep}"
mkdir -p "$WORK"

say() { printf '%s\n' "$*"; }

# The raw image every format is built from, made once.
RAW="$WORK/base.img"
if [ ! -f "$RAW" ]; then
  say "building a ${MIB} MiB NTFS image to wrap…"
  dd if=/dev/zero of="$RAW" bs=1048576 count=0 seek="$MIB" status=none
  "$ENGINE" shell "$RAW" -c "mkfs.ntfs -f -F -L SWEEP /dev/vda" >/dev/null 2>&1
  SIZE="$(stat -c %s "$RAW")"
  [ "$SIZE" = "$((MIB * 1048576))" ] || {
    say "the image was truncated to $SIZE bytes by formatting"; exit 1; }
fi

build() {  # name, then the command that writes $WORK/$name
  local out="$WORK/$1"; shift
  [ -f "$out" ] && return 0
  "$@" >/dev/null 2>&1 || { say "  could not build $(basename "$out")"; return 1; }
}

build sweep.qcow2      "$HERE/scripts/make-qcow2.py"       "$RAW" "$WORK/sweep.qcow2"
build sweep.vdi        "$HERE/scripts/make-vdi.py"         "$RAW" "$WORK/sweep.vdi"
build sweep.vhd        "$HERE/scripts/make-vhd.py"         "$RAW" "$WORK/sweep.vhd"
build sweep-dyn.vhd    "$HERE/scripts/make-vhd.py"         "$RAW" "$WORK/sweep-dyn.vhd" --dynamic
build sweep-sparse.vmdk "$HERE/scripts/make-vmdk-sparse.py" "$RAW" "$WORK/sweep-sparse.vmdk"

where() {  # this image's share, not merely one with a similar name
  mount | awk -v want="$1-img.local:" '$1 ~ want {
    for (i = 1; i <= NF; i++) if ($i == "on") { print $(i+1); exit } }'
}

close() {
  local stem="$1"
  local at; at="$(where "$stem")"
  [ -n "$at" ] && umount -f "$at" >/dev/null 2>&1
  # This image's engine, never every engine there is.
  pkill -f "anylinuxfs mount.*$stem\." >/dev/null 2>&1
  for _ in $(seq 1 20); do
    pgrep -f "anylinuxfs mount.*$stem\." >/dev/null 2>&1 || break
    sleep 1
  done
}

pass=0; fail=0
for img in sweep.qcow2 sweep.vdi sweep.vhd sweep-dyn.vhd sweep-sparse.vmdk; do
  path="$WORK/$img"
  [ -f "$path" ] || { say "$img: not built, skipped"; continue; }
  stem="${img%.*}"
  say ""
  say "=== $img ==="
  close "$stem"
  nohup "$ENGINE" mount --ignore-permissions -w false "$path" \
    > "$WORK/$stem.log" 2>&1 &
  at=""
  for _ in $(seq 1 40); do
    at="$(where "$stem")"
    [ -n "$at" ] && break
    sleep 2
  done
  if [ -z "$at" ]; then
    say "  did not mount; see $WORK/$stem.log"
    fail=$((fail + 1))
    continue
  fi
  say "  mounted at $at"
  if "$HERE/scripts/copy-torture.sh" "$at" 2>&1 | sed 's/^/  /'; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
  fi
  close "$stem"
done

say ""
say "=== $pass formats written and read back, $fail failed ==="
[ "$fail" -eq 0 ]
