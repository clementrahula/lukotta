#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# What happens when somebody opens the second volume on a Linux laptop disk.
#
#   ./scripts/lvm-lock-rule.sh
#
# A LUKS container holding LVM, with root and home as separate logical volumes
# in one partition, is what Ubuntu and Fedora install by default. It is
# therefore the most likely Linux disk anybody plugs into a Mac.
#
# The engine locks whole physical partitions, not logical volumes, because that
# is the granularity a file lock can have. From its README:
#
#   Multi-mount relies on file locks (to prevent data corruption) and we can
#   only lock entire physical partitions. That means you can only mount
#   multiple logical volumes from the same partition if you mount all of them
#   read-only.
#
# Measured here on 2026-09-01, against luks-multi.img -- LUKS2 over LVM with
# three btrfs volumes, root, home and backup, in one partition:
#
#   one volume read-write                    mounts, writable
#   a second read-write, first still open    Failed to acquire lock on device:
#                                            file already locked
#   a second READ-ONLY, first still writable  the same lock error
#   all three read-only                      all three mount, all readable
#
# That third line is the one that matters, and it was nearly missed. The app
# already ends its mount ladder by retrying read-only -- "where read-write was
# asked for and every attempt at it failed, the same attempts are made again
# read-only rather than reporting a drive that cannot be opened" -- so the
# obvious conclusion was that this case is already handled gracefully.
#
# It is not. The lock is held read-write by the volume already open, so a
# read-only second is refused exactly like a read-write one. Read-only is only
# enough when *every* volume on the partition is read-only, the first included.
# The existing fallback therefore runs its whole ladder and still fails, and
# what reaches the person is a drive that would not open.
#
# So the rule is real and it is exactly as written. What matters is what the
# person sees. Today the app has no notion of any of this, so the second volume
# fails and whatever the engine said travels to the screen -- which is a raw
# lock error, about a device, for something the person did not do wrong.
#
# THE DECISION, so it is not re-litigated
#
# A volume opened while another on the same partition is already open is opened
# read-only, and shown as read-only, rather than failing.
#
# Access beats an error dialog, and the app already has a read-only state with
# a name and a place in the window -- so this is not a new prompt, a new error,
# or a new thing to understand. The alternative that keeps everything writable
# is to demote the volume already open, and taking away something a person
# already has in order to give them something they just asked for is worse than
# either. Asking them which they would prefer is worse still: they would be
# choosing between two consequences of a file-lock granularity they should
# never have to hear about.
#
# The zsh trap, which cost a run: `$P:root` is not "$P then :root". zsh reads
# `:r` as the root modifier and `:h` as the head modifier, so `lvm:vg:$P:root`
# expands to `lvm:vg:/dev/disk5s1oot` and `$P:home` to `lvm:vg:/devome`, and
# the engine answers "Invalid LVM disk path" to a question nobody asked. Brace
# the variable: `${P}:root`.
set -uo pipefail
V="${LUKOTTA_TESTVOLS:-$HOME/.lukotta-testvols}"
IMG="$V/luks-multi.img"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Dev.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
[ -f "$IMG" ] || { echo "error: no $IMG -- run make-test-volumes.sh" >&2; exit 2; }
[ -x "$ENGINE" ] || { echo "error: no engine at $ENGINE" >&2; exit 2; }
APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
  "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo com.lukotta)"
export ANYLINUXFS_HOME="$HOME/Library/Application Support/$APP_ID/engine"
export ALFS_PASSPHRASE='lukotta-test-pass'   # invented, and in the maker script

DEV=""
cleanup() {
  for m in $(mount | awk '/FEDORA/ {for(i=1;i<=NF;i++) if($i=="on") print $(i+1)}'); do
    umount -f "$m" >/dev/null 2>&1
  done
  pkill -9 -f 'anylinuxfs mount.*fedoravg' >/dev/null 2>&1
  [ -n "$DEV" ] && hdiutil detach "$DEV" >/dev/null 2>&1
}
trap cleanup EXIT

DEV="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" \
       2>/dev/null | awk 'NR==1{print $1}')"
[ -n "$DEV" ] || { echo "error: could not attach the image" >&2; exit 1; }
P="${DEV}s1"
echo "attached $DEV, partition $P"

pass=0; fail=0
note() { if [ "$1" = ok ]; then pass=$((pass+1)); printf '  ok   %s\n' "$2";
         else fail=$((fail+1)); printf '  FAIL %s\n' "$2"; fi }

open_lv() {  # lv-name, label, extra args...
  local lv="$1" label="$2"; shift 2
  nohup "$ENGINE" mount --ignore-permissions -w false "$@" \
    "lvm:fedoravg:${P}:${lv}" > "/tmp/lvm-$lv.log" 2>&1 < /dev/null &
  for _ in $(seq 1 45); do
    local m; m="$(mount | awk -v l="$label" '$0 ~ l {for(i=1;i<=NF;i++) if($i=="on") print $(i+1)}' | head -1)"
    [ -n "$m" ] && { echo "$m"; return 0; }
    sleep 2
  done
  return 1
}

A="$(open_lv root FEDORAROOT)" && note ok "the first volume opens" \
  || note no "the first volume opens"
if [ -n "${A:-}" ] && touch "$A/.wtest" 2>/dev/null; then
  rm -f "$A/.wtest"; note ok "the first volume is writable"
else note no "the first volume is writable"; fi

if B="$(open_lv home FEDORAHOME)"; then
  note no "the second volume on the same partition is refused (it mounted at $B)"
else
  if grep -qi 'already locked' /tmp/lvm-home.log 2>/dev/null; then
    note ok "the second volume is refused, and the reason is the partition lock"
  else
    note no "the second volume is refused for the documented reason"
    sed 's/^/       /' /tmp/lvm-home.log 2>/dev/null | tail -3
  fi
fi

cleanup; trap - EXIT
DEV="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" \
       2>/dev/null | awk 'NR==1{print $1}')"
P="${DEV}s1"
trap cleanup EXIT
n=0
for pair in "root FEDORAROOT" "home FEDORAHOME" "backup FEDORABACKUP"; do
  set -- $pair
  m="$(open_lv "$1" "$2" -o ro)" && [ -n "$m" ] && ls "$m" >/dev/null 2>&1 && n=$((n + 1))
done
note "$([ "$n" -eq 3 ] && echo ok || echo no)" \
  "all three open together when all three are read-only ($n of 3)"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
