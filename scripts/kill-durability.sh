#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Whether a write that was told it had been committed is still there after the
# machine serving it dies.
#
#   ./scripts/kill-durability.sh [megabytes]
#
# `dd conv=fsync` returns only once the NFS client's COMMIT has been answered,
# so an application that fsyncs and is told it succeeded has, at that moment,
# every guarantee the platform offers. This kills the machine straight after
# and looks again.
#
# The target is a scratch disk image attached with hdiutil rather than a real
# drive. That is not a weaker test: what decides the outcome is whether the
# thing under the guest is a device node or a regular file, and an attached
# image is a device node exactly as a USB disk is. It is the reason the fault
# hid for so long -- an image handed to the engine as a *file* survived this
# test byte-identical, and the same bytes on a device disappeared, which read
# like a filesystem problem and was a device-flush problem.
#
# It also means the drive nobody has a second copy of is not in the experiment.
# An abrupt kill is the whole point of the test and it leaves NTFS dirty; doing
# that repeatedly to somebody's only backup to learn something a scratch image
# can teach is not a trade worth making.
set -u

MB="${1:-8}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP="${LUKOTTA_APP:-/Applications/Lukotta Dev.app}"
ENGINE="${LUKOTTA_ENGINE:-$APP/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
[ -x "$ENGINE" ] || { echo "no engine at $ENGINE"; exit 1; }

# Driven through the engine rather than through `--drive`, because the app's
# own scan does not list a disk image attached with hdiutil and there is
# nothing in the flush path that the daemon contributes. The device node is
# owned by whoever attached it, so no elevation is needed either.
WORK="$(mktemp -d)"
IMG="$WORK/durability.img"
DEV=""

cleanup() {
  [ -n "$DEV" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }

# Formatted as NTFS by the guest, before it is attached: `anylinuxfs shell`
# takes a file. It also truncates one, so the size is checked afterwards rather
# than assumed -- a short image leaves a filesystem describing a device larger
# than the one underneath it, which fails later and looks like something else
# entirely.
dd if=/dev/zero of="$IMG" bs=1048576 count=0 seek=512 status=none
say "formatting…"
"$ENGINE" shell "$IMG" -c "mkfs.ntfs -f -F -L DURTEST /dev/vda" >/dev/null 2>&1
SIZE_NOW="$(stat -c %s "$IMG")"
[ "$SIZE_NOW" = "$((512 * 1048576))" ] || {
  say "the image was truncated to $SIZE_NOW bytes by formatting"; exit 1; }

DEV="$(hdiutil attach -nomount "$IMG" | awk 'NR==1{print $1}')"
[ -n "$DEV" ] || { say "could not attach the image"; exit 1; }
say "attached $DEV"

where() {
  mount | awk -v want="$(basename "$DEV")." '$1 ~ want {
    for (i = 1; i <= NF; i++) if ($i == "on") { print $(i+1); exit } }'
}

open_device() {
  nohup "$ENGINE" mount --ignore-permissions "$DEV" > "$WORK/engine.log" 2>&1 &
  for _ in $(seq 1 40); do
    [ -n "$(where)" ] && return 0
    sleep 2
  done
  return 1
}

say "opening…"
open_device || { say "it did not mount"; sed 's/^/    /' "$WORK/engine.log"; exit 1; }
MOUNT="$(where)"
say "mounted at $MOUNT"

# Write, and do not return until the write is committed.
dd if=/dev/urandom of="$MOUNT/witness.bin" bs=1048576 count="$MB" conv=fsync status=none
WANT="$(shasum -a 256 "$MOUNT/witness.bin" | awk '{print $1}')"
say "wrote ${MB} MiB, fsync returned, sha256 ${WANT:0:16}…"

# The death the test is about. Not a shutdown: an application that fsynced has
# been promised the data survives this.
#
# Matched on this device, never on "anylinuxfs mount" alone. A sweep of every
# engine takes down whatever else is open, and has dirtied a real drive three
# times in the course of this work.
PIDS="$(pgrep -f "anylinuxfs mount.*$(basename "$DEV")")"
[ -n "$PIDS" ] || { say "no machine to kill"; exit 1; }
say "killing $PIDS"
kill -9 $PIDS 2>/dev/null
sleep 3
umount -f "$MOUNT" >/dev/null 2>&1

say "reopening…"
open_device || { say "RESULT: it did not reopen at all"; exit 1; }
MOUNT="$(where)"

if [ ! -e "$MOUNT/witness.bin" ]; then
  say "RESULT: the file is not there. A committed write was lost."
  exit 1
fi
GOT="$(shasum -a 256 "$MOUNT/witness.bin" | awk '{print $1}')"
SIZE="$(stat -c %s "$MOUNT/witness.bin")"
if [ "$GOT" = "$WANT" ]; then
  say "RESULT: survived, byte-identical ($SIZE bytes)"
else
  say "RESULT: present but changed — $SIZE bytes, sha256 ${GOT:0:16}… wanted ${WANT:0:16}…"
  exit 1
fi

pkill -f "anylinuxfs mount.*$(basename "$DEV")" >/dev/null 2>&1
