#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# A volume Windows left dirty is opened writable, and the data is still there.
#
#   ./scripts/dirty-ntfs-repair.sh [outdir]
#
# The app clears the dirty flag rather than demoting the volume to read-only,
# because somebody who asked for writable is owed writable. The tests cover
# what the repair refuses -- a hibernated volume, a volume ntfsfix -n will not
# vouch for -- by running the real command against stubs. What they do not
# cover is the thing that actually matters: that a volume which goes through
# the repair still holds every byte it held before.
#
# ntfsfix does not replay the NTFS journal. Nothing on Linux does; it discards
# it. So "the flag is cleared and it mounts" is not the claim worth making, and
# this makes the other one: known contents, written and checksummed before the
# volume is left dirty, compared byte for byte after the app has opened it.
#
# The volume is made dirty the way a real one becomes dirty -- by the machine
# holding it going away mid-write, rather than by flipping a bit and hoping the
# result resembles one.
#
# On an image throughout. Nothing here touches a drive anybody owns.
#
# Result on 2026-09-01: volume confirmed dirty, opened by the app through the
# repair action, writable rather than demoted, and all 41 files byte-identical
# afterwards. PASS.
#
# The refusal was demonstrated on the way there, on real damage rather than a
# stub. An earlier version dirtied the volume by killing the machine with two
# hundred megabytes in flight, which left $MFTMirr not matching $MFT, and the
# guard would not repair it: "Remount failed: I/O error", no mount, nothing
# written. Clearing a flag on a volume whose mirror is wrong is how data goes
# missing, and the app declined to.
set -uo pipefail
OUT="${1:-$HOME/.lukotta-testvols}"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Beta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
[ -x "$ENGINE" ] || { echo "error: no engine at $ENGINE" >&2; exit 2; }
APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
  "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo com.lukotta)"
export ANYLINUXFS_HOME="$HOME/Library/Application Support/$APP_ID/engine"
mkdir -p "$OUT"
IMG="$OUT/dirty-ntfs.img"
WORK="$(mktemp -d)"
trap 'pkill -f "anylinuxfs mount.*dirty-ntfs" >/dev/null 2>&1; rm -rf "$WORK"' EXIT

# A fresh NTFS volume, made by the guest, which is the only thing here that
# carries mkfs.ntfs.
rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=1048576 count=0 seek=600 2>/dev/null
"$ENGINE" shell "$IMG" -c 'mkfs.ntfs -Q -L DIRTYTEST /dev/vda >/dev/null 2>&1 && echo made' \
  > "$WORK/mkfs.log" 2>&1
grep -q made "$WORK/mkfs.log" || { echo "error: could not make the volume" >&2; cat "$WORK/mkfs.log" >&2; exit 1; }
echo "made a clean NTFS volume"

where() {
  mount | awk -v want="$(basename "$IMG" .img)-img.local:" \
    '$1 ~ want {for(i=1;i<=NF;i++) if($i=="on") {print $(i+1); exit}}'
}

# The engine names a share after what it was made from -- "<image>-img.local:
# /mnt/LABEL" for a file, "<device>.local:/mnt/LABEL" for a drive -- and only a
# mount made by hand against the guest's address says 172.27. Polling for the
# address therefore waited out its timeout on a volume that had mounted
# perfectly well, and reported that the volume would not open.
# The app writes its own custom actions into the engine's config.toml as part
# of building a mount, so an action named on an engine command line that the app
# never built does not exist. Asking for the repair action this way answered
# "unknown custom action: lukottarepair" and was read as the app refusing to
# open a dirty volume -- the app had not been anywhere near it.
#
# Item 7 is about what the app does, so the app is what runs. This installs the
# actions the same way a mount does, before any of them is named.
"$ENGINE" --version >/dev/null 2>&1 || true
# Whether this bundle's daemon exists at all.
#
# Without one the app cannot mount anything, sits in its run loop until the
# timeout below, and leaves no configuration -- which this script then reported
# as "the app did not leave its actions", a sentence about the app that was
# entirely about the machine. Installing a channel's first daemon asks for an
# administrator password, so the answer is to run this against a channel that
# has one, and to say which.
APP="$APP_BUNDLE/Contents/MacOS/$(basename "$APP_BUNDLE" .app)"
# And whether this bundle can be driven at all.
#
# The headless switches live inside `#if DEVTOOLS`, and a beta or release build
# does not carry them. Handed --drive anyway the app does not complain: it
# launches, hides its window and sits in its run loop until something kills it,
# which reads exactly like a mount that hangs and was read as one for most of a
# morning. One second of strings answers it.
can_be_driven() {
  # grep -c rather than -q, and a count rather than an exit status. Under
  # `set -o pipefail`, `grep -q` matches, exits at once, `strings` dies of
  # SIGPIPE, and the pipeline reports 141 -- so the check refused every bundle
  # that was fine, including the one it had just been proved against.
  [ "$(strings -a "$APP" 2>/dev/null | /usr/bin/grep -c -- "--drive")" -gt 0 ]
}

daemon_is_there() {
  [ -f "/Library/LaunchDaemons/$APP_ID.helper.plist" ]
}

prepare_actions() {
  if ! can_be_driven; then
    echo "error: $APP_BUNDLE has no --drive; it was not built with devtools" >&2
    echo "       build one with LUKOTTA_BRANDING=beta LUKOTTA_DEVTOOLS=1 ./build-app.sh" >&2
    return 2
  fi
  if ! daemon_is_there; then
    echo "error: no daemon for $APP_ID; this channel cannot mount on this Mac" >&2
    echo "       installed: $(find /Library/LaunchDaemons -name 'com.lukotta*.helper.plist' \
      -exec basename {} .helper.plist \; | tr '\n' ' ')" >&2
    echo "       run this with LUKOTTA_ENGINE pointing at one of those bundles" >&2
    return 2
  fi
  # On a clean volume, never on the dirty one.
  #
  # The app writes its repair action while building a writable NTFS mount, and
  # the dirty volume is the one that cannot be mounted without that action. So
  # asking the app to open the dirty image installs nothing and the harness then
  # reports that the app could not open a dirty volume -- which it never tried.
  local clean="$OUT/sweep/base.img"
  [ -f "$clean" ] || clean="$IMG"
  local dev
  dev="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$clean" \
    2>/dev/null | head -1 | awk '{print $1}')"
  [ -n "${dev:-}" ] || return 1
  # The app's own account, kept whether it works or not.
  #
  # A run that stalls prints nothing at all: the app writes to the unified log
  # and its standard output stays empty, so a stall looked exactly like an app
  # that had quietly done nothing. Ten minutes of silence, and the reason --
  # the same three lines repeating five times a second -- was there the whole
  # time and only ever found by going and looking by hand.
  local started
  started="$(date '+%Y-%m-%d %H:%M:%S')"
  timeout 600 "$APP_BUNDLE/Contents/MacOS/$(basename "$APP_BUNDLE" .app)" \
    --drive open="$dev" > "$WORK/app.log" 2>&1
  /usr/bin/log show --start "$started" --info --debug \
    --predicate "subsystem CONTAINS \"$APP_ID\"" --style compact \
    > "$WORK/app-unified.log" 2>/dev/null || true
  # Found under the device's name, not the image's. `where` looks for
  # "<image>-img.local", which is what the engine calls a share made from a
  # file; the app was handed a device, so the share is "diskN.local" and this
  # found nothing and unmounted nothing. The clean volume was left mounted
  # after every run, and a stray /Volumes/SWEEP from an earlier one is exactly
  # the sort of thing this harness has been fooled by before.
  local point
  point="$(mount | awk -v want="$(basename "$dev").local:" \
    '$1 ~ want {for(i=1;i<=NF;i++) if($i=="on") {print $(i+1); exit}}')"
  [ -n "$point" ] && { umount "$point" >/dev/null 2>&1 \
    || diskutil unmount force "$point" >/dev/null 2>&1; }
  hdiutil detach "$dev" -quiet 2>/dev/null
  # The engine keeps its configuration one directory further down. Looking in
  # the wrong place here made this report that the app had left no actions,
  # every time, whether it had or not.
  if grep -q "custom_actions.lukottarepair" \
    "$ANYLINUXFS_HOME/.anylinuxfs/config.toml" 2>/dev/null; then
    return 0
  fi
  # What it was doing instead, in its own words: the most repeated line, which
  # is what a stall looks like, and then the last few.
  if [ -s "$WORK/app-unified.log" ]; then
    echo "the app left no repair action. What it was doing:" >&2
    sed 's/^[^]]*\] //' "$WORK/app-unified.log" | sort | uniq -c | sort -rn \
      | head -3 | sed 's/^/      /' >&2
    tail -3 "$WORK/app-unified.log" | cut -c1-150 | sed 's/^/      /' >&2
  fi
  return 1
}

open_it() {  # extra engine args
  pkill -f "anylinuxfs mount.*dirty-ntfs" >/dev/null 2>&1; sleep 3
  nohup "$ENGINE" mount --ignore-permissions -w false -t ntfs3 "$@" "$IMG" > "$WORK/engine.log" 2>&1 &
  # This image's share, not any engine mount: the owner's drive is mounted the
  # whole time, so waiting for ":/mnt/" returns at once and the caller then asks
  # where a volume is that has not appeared yet.
  for _ in $(seq 1 40); do [ -n "$(where)" ] && return 0; sleep 2; done
  return 1
}
# This image's mount, not the last engine mount in the table. Another volume
# may be open, and a mount whose machine has been killed stays in the table
# answering `mount` and failing every request -- picking that one reports the
# repair as read-only and the data as gone, when neither is true.

# Known contents, checksummed before anything goes wrong with the volume.
open_it -a lukottatuned || { echo "error: clean volume would not open" >&2; exit 1; }
VOL="$(where)"; echo "opened clean at $VOL"
SRC="$WORK/src"; mkdir -p "$SRC"
for i in $(seq 1 40); do head -c 200000 /dev/urandom > "$SRC/f$i.bin"; done
printf 'the byte that must survive' > "$SRC/witness.txt"
ditto "$SRC" "$VOL/before" >/dev/null 2>&1
sync

# Closed properly before anything is broken, and opened again. sync on the Mac
# does not reach the guest's cache, and the guest is about to be killed -- so
# without this the corpus is still in memory when the machine dies and the test
# reports every file lost, which is the fault it exists to detect and not the
# one that happened.
#
# Closed by unmounting the share and letting the engine notice, not by killing
# it. Killing the machine is what dirties an NTFS volume -- it is the very thing
# done deliberately two steps below -- so a pkill here left the volume dirty and
# the reopen met "wrong fs type, bad option, bad superblock", which is ntfs3
# refusing a volume that was never closed.
umount "$VOL" >/dev/null 2>&1 || umount -f "$VOL" >/dev/null 2>&1
for _ in $(seq 1 30); do
  pgrep -f "anylinuxfs mount.*$(basename "$IMG")" >/dev/null 2>&1 || break
  sleep 2
done
open_it -a lukottatuned || {
  echo "error: could not reopen after writing the corpus" >&2
  sed -n '1,25p' "$WORK/engine.log" >&2
  exit 1
}
VOL="$(where)"
[ -n "$VOL" ] || { echo "error: reopened but nowhere findable" >&2; exit 1; }
echo "closed and reopened cleanly; the corpus is on the image"
BEFORE="$WORK/before.sums"
(cd "$SRC" && find . -type f -exec shasum -a 256 {} \; | sort) > "$BEFORE"
echo "wrote $(wc -l < "$BEFORE" | tr -d ' ') files and recorded their sums"

# Dirty it the way Windows leaves a volume dirty: mounted read-write and never
# unmounted. The machine is taken away with the filesystem still mounted, so the
# dirty flag stays set and the journal is unfinished -- which is the state a
# drive is in after a Windows machine is switched off with it attached.
#
# Not mid-write, which was tried first and is a different fault. Killing the
# machine while two hundred megabytes were in flight left $MFTMirr not matching
# $MFT, and ntfsfix would not vouch for that -- correctly, since clearing a flag
# on a volume whose mirror is wrong is how data goes missing. That refusal is
# worth having and is checked separately; it is not what a dirty volume is.
sync
sleep 2
pkill -9 -f "anylinuxfs mount.*dirty-ntfs" >/dev/null 2>&1
sleep 3
umount -f "$VOL" >/dev/null 2>&1
sleep 3
echo "machine taken away with the volume still mounted; it should now be dirty"

# Confirm it really is, rather than assuming the kill was enough.
"$ENGINE" shell "$IMG" -c 'ntfsfix -n /dev/vda 2>&1 | head -20' > "$WORK/state.log" 2>&1
if grep -qiE 'dirty|unclean|journal|logfile' "$WORK/state.log"; then
  echo "confirmed dirty"
else
  echo "NOTE: the volume did not come back dirty; the rest still runs but proves less"
  sed -n '1,6p' "$WORK/state.log"
fi

# Open it the way the app does when a volume is dirty.
prepare_actions
case $? in
  0) ;;
  2) exit 2 ;;
  *) echo "note: the app did not leave its actions in config.toml" ;;
esac
if open_it -a lukottarepair; then
  VOL="$(where)"; echo "opened dirty volume at $VOL"
else
  echo "FAIL: the app could not open the dirty volume at all" >&2
  sed -n '1,20p' "$WORK/engine.log" >&2
  exit 1
fi
[ -n "$VOL" ] || { echo "FAIL: opened, but no mount for this image" >&2; exit 1; }

# Writable, because that is what was asked for.
if printf 'writable' > "$VOL/after-repair.txt" 2>/dev/null; then
  echo "ok   the repaired volume takes a write"
else
  echo "FAIL the repaired volume is read-only" >&2; fail=1
fi

# And every byte still there.
AFTER="$WORK/after.sums"
(cd "$VOL/before" && find . -type f -exec shasum -a 256 {} \; | sort) > "$AFTER"
if diff -q "$BEFORE" "$AFTER" >/dev/null 2>&1; then
  echo "ok   all $(wc -l < "$AFTER" | tr -d ' ') files byte-identical after the repair"
else
  echo "FAIL the repair changed the data:" >&2
  diff "$BEFORE" "$AFTER" | head -10 >&2
  fail=1
fi
if [ -z "${fail:-}" ]; then
  echo "PASS"
else
  echo "FAILED"
  exit 1
fi
