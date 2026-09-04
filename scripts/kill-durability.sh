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
# Takes a device: `/dev/diskNsM` for a real drive, or nothing for a scratch
# image attached with hdiutil.
#
# **The scratch image does not reproduce the fault.** It was chosen because an
# attached image is a device node exactly as a USB disk is, so it looked like
# the same code path at no risk to anybody's drive. Run against an engine
# without patches/imago-flush-device-nodes.patch, which is the engine the fault
# was measured on, it returned the 8 MB byte-identical. Being a device node is
# therefore not the whole condition: writes to an attached image reach the
# backing file through the host's buffer cache, and killing the guest does not
# discard that, so macOS still writes it out. A raw physical device has no such
# cache behind it.
#
# So a pass here is not evidence. Only a real drive is, which is why the device
# is an argument.
set -u

DEVICE="${1:-}"
MB="${2:-8}"
APP="${LUKOTTA_APP:-/Applications/Lukotta Dev.app}"
ENGINE="${LUKOTTA_ENGINE:-$APP/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
[ -x "$ENGINE" ] || { echo "no engine at $ENGINE"; exit 1; }

# The app's own engine home, not ~/.anylinuxfs. `vm_image::init` upgrades the
# flock on /tmp/anylinuxfs.lock to exclusive when the rootfs it is pointed at
# needs unpacking, and an exclusive lock cannot be had while the app holds
# shared ones for the drives already open. Pointed at a home that is already
# prepared, init has nothing to do and never asks. Without this the run fails
# with "another instance is already running", which reads like a stale process
# and is a rootfs that was never initialised.
export ANYLINUXFS_HOME="${ANYLINUXFS_HOME:-$HOME/Library/Application Support/com.lukotta.dev/engine}"
[ -d "$ANYLINUXFS_HOME/.anylinuxfs/alpine" ] || {
  echo "no prepared guest in $ANYLINUXFS_HOME"; exit 1; }

# Driven through the engine rather than through `--drive`, because the app's
# own scan does not list a disk image attached with hdiutil and there is
# nothing in the flush path that the daemon contributes. The device node is
# owned by whoever attached it, so no elevation is needed either.
WORK="$(mktemp -d)"
IMG="$WORK/durability.img"
DEV=""

cleanup() {
  [ "${REAL:-0}" = 0 ] && [ -n "$DEV" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }

# Opening, and finding what was opened.
#
# Both were called and neither was ever written. `open_device` appears in no
# version of this file in the history, so this harness has never run past the
# line that calls it -- while its own head states results as though it had
# measured them. Whatever produced those numbers, it was not this.
#
# A real drive goes through the app, which is the only route that holds it:
# /dev/diskNsM is root:operator and the privileged daemon hands the descriptor
# over. An image goes through the engine directly, as the note above says, since
# the app's scan does not list one attached with hdiutil.
open_device() {
  if [ "${REAL:-0}" = 1 ]; then
    timeout 300 "$EXE" --drive open="$DEV" > "$WORK/engine.log" 2>&1 || return 1
  else
    nohup "$ENGINE" mount -w false --ignore-permissions "$IMG" \
      > "$WORK/engine.log" 2>&1 &
  fi
  local _
  for _ in $(seq 1 60); do
    [ -n "$(where)" ] && return 0
    sleep 2
  done
  return 1
}

# The share the engine made, by the name it gives it: after the device for a
# plain volume, after the volume group for a container. Deepest first, because a
# container serves its volumes inside a parent and the parent is a one-megabyte
# tmpfs with nothing worth writing to on it.
where() {
  mount | /usr/bin/grep '\.local:' | awk '{print $3}' \
    | awk '{print length, $0}' | sort -rn | cut -d" " -f2- | head -1
}

# A real drive is opened through the app, the only route that holds the device:
# /dev/diskNsM is root:operator and the privileged daemon hands the descriptor
# over. Nothing is formatted and nothing already on it is touched; one file is
# written into a folder of this script's own making and removed afterwards.
if [ -n "$DEVICE" ]; then
  EXE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
    "$APP/Contents/Info.plist" 2>/dev/null)"
  [ -x "$EXE" ] || { say "no executable in $APP"; exit 1; }
  DEV="$DEVICE"
  REAL=1
  say "using the drive at $DEV"
else
  # Formatted as NTFS by the guest, before it is attached: `anylinuxfs shell`
  # takes a file. It also truncates one, so the size is checked afterwards
  # rather than assumed; a short image leaves a filesystem describing a device
  # larger than the one underneath it, which fails later and looks like
  # something else entirely.
  dd if=/dev/zero of="$IMG" bs=1048576 count=0 seek=512 status=none
  say "formatting…"
  "$ENGINE" shell "$IMG" -c "mkfs.ntfs -f -F -L DURTEST /dev/vda" >/dev/null 2>&1
  SIZE_NOW="$(stat -c %s "$IMG")"
  [ "$SIZE_NOW" = "$((512 * 1048576))" ] || {
    say "the image was truncated to $SIZE_NOW bytes by formatting"; exit 1; }

  DEV="$(hdiutil attach -nomount "$IMG" | awk 'NR==1{print $1}')"
  [ -n "$DEV" ] || { say "could not attach the image"; exit 1; }
  REAL=0
  say "attached $DEV"
fi

# Anything already served, let go of first.
#
# This kills an engine and leaves its mount in the table: dead, answering
# `mount`, answering nothing else. The next run then found that stale mount
# with where(), wrote into it, and got "Input/output error" -- reported first
# as a lost committed write and later, once the harness checked, as a write
# that never happened. Neither was about the drive.
for stale in $(mount | /usr/bin/grep '\.local:' | awk '{print $3}' \
               | awk '{print length, $0}' | sort -rn | cut -d" " -f2-); do
  umount "$stale" >/dev/null 2>&1 || umount -f "$stale" >/dev/null 2>&1
done
sleep 2

say "opening…"
open_device || { say "it did not mount"; sed 's/^/    /' "$WORK/engine.log"; exit 1; }
MOUNT="$(where)"
say "mounted at $MOUNT"

# Write, and do not return until the write is committed.
# Written, and checked to have been written.
#
# This did neither: it ran mkdir and dd, ignored both, and went straight to
# killing the machine. A drive that answered "Input/output error" to the mkdir
# therefore produced "RESULT: the file is not there. A committed write was
# lost." -- about a write that never happened. A harness that cannot tell a
# lost write from an unwritten one is worse than none, because the answer it
# gives is the alarming one.
if ! mkdir -p "$MOUNT/lukotta-durability" 2>"$WORK/mkdir.err"; then
  say "the drive would not take a directory: $(head -1 "$WORK/mkdir.err")"
  say "nothing was written, so there is nothing to say about durability"
  exit 2
fi
if ! dd if=/dev/urandom of="$MOUNT/lukotta-durability/witness.bin" \
     bs=1048576 count="$MB" conv=fsync status=none 2>"$WORK/dd.err"; then
  say "the write itself failed: $(head -1 "$WORK/dd.err")"
  say "nothing was committed, so there is nothing to say about durability"
  exit 2
fi
WROTE="$(stat -c %s "$MOUNT/lukotta-durability/witness.bin" 2>/dev/null || echo 0)"
if [ "$WROTE" != "$((MB * 1048576))" ]; then
  say "only $WROTE bytes of $((MB * 1048576)) arrived; not a durability question"
  exit 2
fi
WANT="$(shasum -a 256 "$MOUNT/lukotta-durability/witness.bin" | awk '{print $1}')"
[ -n "$WANT" ] || { say "the file could not be read back before the kill"; exit 2; }
say "wrote ${MB} MiB, fsync returned, sha256 ${WANT:0:16}…"

# WAIT tells the difference between a flush and a background writeback.
#
# If the file survives a kill delayed by some seconds but not an immediate one,
# then nothing flushed it when fsync said so -- the data reached the drive later
# on its own, and the promise fsync made was never kept. If it dies either way,
# the writes are not reaching the drive at all.
if [ "${WAIT:-0}" != "0" ]; then
  say "waiting ${WAIT}s before the kill"
  sleep "$WAIT"
fi

# The death the test is about. Not a shutdown: an application that fsynced has
# been promised the data survives this.
#
# Matched on this device, never on "anylinuxfs mount" alone. A sweep of every
# engine takes down whatever else is open, and has dirtied a real drive three
# times in the course of this work.
PIDS="$(pgrep -f "anylinuxfs mount.*$(basename "$DEV")")"
[ -n "$PIDS" ] || { say "no machine to kill"; exit 1; }
say "killing $PIDS"
# Word-split on purpose: PIDS is a list. Said so, rather than quoted
  # into one argument that is not a pid.
  # shellcheck disable=SC2086
  kill -9 $PIDS 2>/dev/null
sleep 3
umount -f "$MOUNT" >/dev/null 2>&1

say "reopening…"
open_device || { say "RESULT: it did not reopen at all"; exit 1; }
MOUNT="$(where)"

if [ ! -e "$MOUNT/lukotta-durability/witness.bin" ]; then
  say "RESULT: the file is not there. A committed write was lost."
  exit 1
fi
GOT="$(shasum -a 256 "$MOUNT/lukotta-durability/witness.bin" | awk '{print $1}')"
SIZE="$(stat -c %s "$MOUNT/lukotta-durability/witness.bin")"
if [ "$GOT" = "$WANT" ]; then
  say "RESULT: survived, byte-identical ($SIZE bytes)"
else
  say "RESULT: present but changed — $SIZE bytes, sha256 ${GOT:0:16}… wanted ${WANT:0:16}…"
  exit 1
fi

rm -rf "$MOUNT/lukotta-durability"
[ "$REAL" = 1 ] || pkill -f "anylinuxfs mount.*$(basename "$DEV")" >/dev/null 2>&1
