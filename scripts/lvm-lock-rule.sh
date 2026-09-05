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
# The rule is real. What it is not is something a person using this app meets,
# and that took driving the app rather than the engine to find out.
#
# Opening the partition -- which is what the app does -- mounts every logical
# volume in it from ONE machine:
#
#     /Volumes/disk5s1/FEDORAROOT
#     /Volumes/disk5s1/FEDORAHOME
#     /Volumes/disk5s1/FEDORABACKUP
#
#   all three writable: 3 of 3
#   concurrent copies into two of them: 4 of 4 byte-identical in each
#
# One machine takes one lock on the partition, so there is nothing for a second
# to collide with. The restriction bites when several machines each want the
# same partition, which is what `lvm:vg:disk:lv` one at a time asks for -- and
# that is what the measurements below were doing. It is the engine's own
# interface being exercised, not the app's route.
#
# The earlier version of this file recorded a UX cliff on the strength of it:
# "the app has no notion of any of this, so the second volume fails and a raw
# lock error travels to the screen". That was wrong, and wrong in the most
# ordinary way -- the test drove a layer the app does not use, and the failure
# it produced was real for that layer and unreachable from the app.
#
# THE DECISION, so it is not re-litigated
#
# Nothing to decide, as it turns out. The app opens the container and serves
# every volume in it from one machine, which is both the behaviour a person
# wants and the one that never meets the lock. A design was written here for
# demoting volumes to read-only and weighed against asking the user; it was
# answering a problem that does not exist on this path, and it is gone.
#
# What is worth keeping is the guard against reintroducing it: anything that
# opens logical volumes one at a time, each in its own machine, will meet the
# partition lock and will have to answer for it.
#
# The zsh trap, which cost a run: `$P:root` is not "$P then :root". zsh reads
# `:r` as the root modifier and `:h` as the head modifier, so `lvm:vg:$P:root`
# expands to `lvm:vg:/dev/disk5s1oot` and `$P:home` to `lvm:vg:/devome`, and
# the engine answers "Invalid LVM disk path" to a question nobody asked. Brace
# the variable: `${P}:root`.
set -uo pipefail
V="${LUKOTTA_TESTVOLS:-$HOME/.lukotta-testvols}"
IMG="$V/luks-multi.img"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Beta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
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

# Each attempt keeps its own log.
#
# It was one file per volume, so the read-only phase opened the same three
# volumes again and truncated what the read-write phase had written. The
# read-write findings were still correct -- they are read while that phase is
# running -- but by the end every log was empty, and "2 of 3" could not say
# which volume or why. PHASE is set before each round.
PHASE="rw"
lv_log() { echo "/tmp/lvm-$PHASE-$1.log"; }

open_lv() {  # lv-name, label, extra args...
  local lv="$1" label="$2"; shift 2
  nohup "$ENGINE" mount --ignore-permissions -w false "$@" \
    "lvm:fedoravg:${P}:${lv}" > "$(lv_log "$lv")" 2>&1 < /dev/null &
  for _ in $(seq 1 45); do
    local m; m="$(mount | awk -v l="$label" '$0 ~ l {for(i=1;i<=NF;i++) if($i=="on") print $(i+1)}' | head -1)"
    [ -n "$m" ] && { echo "$m"; return 0; }
    sleep 2
  done
  return 1
}

# shellcheck disable=SC2015
A="$(open_lv root FEDORAROOT)" && note ok "the first volume opens" \
  || note no "the first volume opens"
if [ -n "${A:-}" ] && touch "$A/.wtest" 2>/dev/null; then
  rm -f "$A/.wtest"; note ok "the first volume is writable"
else note no "the first volume is writable"; fi

if B="$(open_lv home FEDORAHOME)"; then
  note no "the second volume on the same partition is refused (it mounted at $B)"
else
  if grep -qi 'already locked' "$(lv_log home)" 2>/dev/null; then
    note ok "the second volume is refused, and the reason is the partition lock"
  else
    note no "the second volume is refused for the documented reason"
    sed 's/^/       /' "$(lv_log home)" 2>/dev/null | tail -3
  fi
fi

cleanup; trap - EXIT
# Settled, not merely asked to stop.
#
# cleanup umounts and sends KILL and returns at once. The next phase then opened
# the same three volumes read-only and reported "2 of 3" -- always the volume
# that had been open read-write, because its engine was still letting go of the
# partition while the read-only open asked for it.
#
# Measured on 2026-09-05: on a machine cleaned and left to settle, all three open
# read-only, 3 of 3, in either order. The rule the header quotes is intact; what
# was being measured was this harness's own previous phase.
for _ in $(seq 1 30); do
  # `pgrep -c` is a GNU spelling; this is BSD pgrep and it answers with its
  # usage text, which is not zero and not a count. Written that way first, and
  # the loop then fell through to the timer on every pass -- a check that reads
  # as running and decides nothing.
  [ "$(pgrep -f 'anylinuxfs mount.*fedoravg' | wc -l | tr -d ' ')" = 0 ] &&
    [ "$(mount | /usr/bin/grep -c FEDORA || true)" = 0 ] && break
  sleep 2
done
DEV="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" \
       2>/dev/null | awk 'NR==1{print $1}')"
P="${DEV}s1"
trap cleanup EXIT
n=0
PHASE="ro"
missed=""
for pair in "root FEDORAROOT" "home FEDORAHOME" "backup FEDORABACKUP"; do
  # Word-split on purpose: pair is two words.
  # shellcheck disable=SC2086
  set -- $pair
  if m="$(open_lv "$1" "$2" -o ro)" && [ -n "$m" ] && ls "$m" >/dev/null 2>&1; then
    n=$((n + 1))
  else
    missed="$missed $1"
  fi
done
note "$([ "$n" -eq 3 ] && echo ok || echo no)" \
  "all three open together when all three are read-only ($n of 3)"
# Which one, and what it said. A count on its own cannot be acted on, and this
# reported "2 of 3" for a morning with every log truncated behind it.
if [ "$n" -ne 3 ]; then
  for lv in $missed; do
    echo "       $lv did not open:"
    sed 's/^/         /' "$(lv_log "$lv")" 2>/dev/null | tail -4
  done
fi

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
