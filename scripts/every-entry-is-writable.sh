#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Whatever mode or flag the disk stores, every entry is readable, writable and deletable from Finder, and nothing else on the volume changes.
#   ./scripts/every-entry-is-writable.sh /dev/diskNsM
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
DEV="${1:?usage: every-entry-is-writable.sh /dev/diskNsM}"
APP_BUNDLE="${LUKOTTA_APP:-/Applications/Lukotta Dev.app}"
APP="$APP_BUNDLE/Contents/MacOS/$(basename "$APP_BUNDLE" .app)"
ENGINE="$APP_BUNDLE/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs"
[ -x "$APP" ] || { echo "no app at $APP"; exit 2; }
[ "$(strings -a "$APP" 2>/dev/null | grep -c -- "--drive")" -gt 0 ] \
  || { echo "$APP has no --drive; rebuild with LUKOTTA_DEVTOOLS=1"; exit 2; }
APP_ID="$(/usr/bin/defaults read "$APP_BUNDLE/Contents/Info.plist" CFBundleIdentifier)"
export ANYLINUXFS_HOME="$HOME/Library/Application Support/$APP_ID/engine"
[ -d "$ANYLINUXFS_HOME/.anylinuxfs/alpine/rootfs" ] \
  || { echo "$APP_ID has not unpacked its guest yet; open a drive with it once"; exit 2; }

# A real drive only. An image is backed by a file, and the host's cache covers
# for what the guest does not do.
[ -b "$DEV" ] || { echo "$DEV is not a block device"; exit 2; }
WORK="$(mktemp -d)"
OPENED=0
cleanup() {
  [ "$OPENED" = 1 ] && "$APP" --drive eject="$DEV" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

served() { mount | grep -F "$(basename "$DEV").local:" | grep ' (nfs' | sed -E 's/^.* on (.*) \(nfs.*$/\1/' | head -n 1; }
[ -z "$(served)" ] || { echo "$DEV is open; eject it first"; exit 2; }

# The flags root cannot override, set where they are stored, on the filesystems
# that store them. NTFS, FAT and exFAT keep no such flag on the disk. The guest
# reads a raw device only as root.
FROZEN=0
kind="$(diskutil info "$DEV" 2>/dev/null | awk -F: '/Type \(Bundle\)/ {gsub(/ /, "", $2); print $2}')"
case "$kind" in
  ntfs | msdos | exfat) echo "  $kind stores no immutable or append-only flag" ;;
  *)
    sudo -n true 2>/dev/null || { echo "setting flags on a Linux filesystem needs sudo without a prompt"; exit 2; }
    prep="$(sudo -n env ANYLINUXFS_HOME="$ANYLINUXFS_HOME" "$ENGINE" shell "$DEV" -c '
fs=$(blkid -o value -s TYPE /dev/vda)
case "$fs" in ext4|xfs|btrfs) ;; *) echo "no-flags $fs"; exit 0 ;; esac
command -v chattr >/dev/null || { echo "no chattr in the guest"; exit 1; }
mkdir -p /tmp/m && mount -t $fs /dev/vda /tmp/m || { echo "prep mount failed"; exit 1; }
d=/tmp/m/lukotta-frozen
mkdir -p $d && echo frozen > $d/immutable.txt && echo appended > $d/append.txt
chattr +i $d/immutable.txt && chattr +a $d/append.txt && lsattr $d && echo flags-set
umount /tmp/m' 2>&1)"
    printf '%s\n' "$prep" | sed 's/^/  guest: /'
    if printf '%s\n' "$prep" | grep -qx 'flags-set'; then
      FROZEN=1
    elif ! printf '%s\n' "$prep" | grep -q '^no-flags '; then
      echo "the immutable and append-only fixture could not be made"; exit 1
    fi
    ;;
esac
HOST="$(basename "$DEV").local"

cat > "$WORK/windows.swift" <<'EOF'
import CoreGraphics
let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
print(all.filter { ($0[kCGWindowOwnerName as String] as? String) == "Finder"
    && ($0[kCGWindowLayer as String] as? Int) == 0 }.count)
EOF
swiftc -O -o "$WORK/finder-windows" "$WORK/windows.swift" 2>/dev/null || { echo "window counter did not build"; exit 2; }

finder_volume() {
  local afp; afp="$(mount | grep -F "@$HOST/" | grep afpfs | sed -E 's/^.* on (.*) \([^()]*\)$/\1/' | head -n 1)"
  if [ -n "$afp" ]; then echo "$afp"; else served; fi
}
open_drive() {
  timeout 900 "$APP" --drive open="$DEV" >/dev/null 2>&1 || { echo "the drive did not open"; exit 1; }
  OPENED=1
  point=""; nfs=""
  for _ in $(seq 1 240); do
    nfs="$(served)"; point="$(finder_volume)"
    [ -n "$nfs" ] && [ -n "$point" ] && { [ "$point" != "$nfs" ] || ! mount | grep -qF "@$HOST/"; } && break
    sleep 1
  done
  [ -n "$point" ] || { echo "the drive did not reach Finder"; exit 1; }
}

open_drive
owner_listing() {
  find "$nfs" -mindepth 1 -maxdepth 2 ! -name 'lukotta-writable-*' ! -path '*/lukotta-writable-*' \
    ! -name 'lukotta-frozen' ! -path '*/lukotta-frozen/*' ! -name '.Trashes' ! -path '*/.Trashes/*' \
    ! -name '.lukotta-*' ! -name '._*' ! -name '.DS_Store' -printf '%y %s %p\n' 2>/dev/null | LC_ALL=C sort
}
owner_before="$(owner_listing)"
TREE="lukotta-writable-$$"
# Stored underneath, as root, so each mode lands on the disk as the writer gave it.
/usr/bin/python3 - "$nfs/$TREE" <<'PY' || { echo "the fixture could not be written"; exit 1; }
import os, sys, hashlib
t = sys.argv[1]
os.makedirs(t)
with open(f"{t}/keep.bin", "wb") as f: f.write(hashlib.sha256(b"keep").digest() * 32768)
for d in ("sealed", "stamped", "readonly"):
    os.makedirs(f"{t}/{d}")
    with open(f"{t}/{d}/inside.txt", "w") as f: f.write(d)
with open(f"{t}/locked.txt", "w") as f: f.write("locked")
for path, mode in (("sealed", 0o700), ("stamped", 0o755), ("readonly", 0o555), ("locked.txt", 0o444),
                   ("sealed/inside.txt", 0o400), ("stamped/inside.txt", 0o644), ("readonly/inside.txt", 0o444)):
    try:
        os.chmod(f"{t}/{path}", mode)
    except OSError as e:
        print(f"  this filesystem stores no mode {oct(mode)} for {path}: {e.strerror}")
PY
keep_sum="$(sha256sum "$nfs/$TREE/keep.bin" | cut -d' ' -f1)"

# Closed and opened again, so every entry is read back off the disk rather than
# served from what the guest still holds in memory.
"$APP" --drive eject="$DEV" >/dev/null 2>&1; OPENED=0
for _ in $(seq 1 60); do [ -z "$(served)" ] && break; sleep 1; done
open_drive
echo "Finder sees the drive at $point"

failed=0
fail() { echo "  FAIL $*"; failed=1; }
ok() { echo "  ok   $*"; }
T="$point/$TREE"
F="$point/lukotta-frozen"

bad="$(find "$T" "$([ "$FROZEN" = 1 ] && echo "$F" || echo "$T")" \
  \( -type d ! -perm -0777 -o -type f ! -perm -0666 \) -printf '%m %p\n' 2>&1)"
if [ -z "$bad" ]; then
  ok "every entry arrives readable and writable by everyone"
else
  fail "entries arrive with bits withheld:"; printf '%s\n' "$bad" | sed 's/^/         /'
fi

for d in sealed stamped readonly; do
  if [ "$(cat "$T/$d/inside.txt" 2>&1)" = "$d" ]; then ok "$d/inside.txt reads"; else fail "$d/inside.txt does not read"; fi
done
if [ "$(sha256sum "$T/keep.bin" 2>/dev/null | cut -d' ' -f1)" = "$keep_sum" ]; then
  ok "keep.bin reads back byte-identical"
else
  fail "keep.bin changed or does not read"
fi

if printf ' written' >> "$T/locked.txt" 2>/dev/null && [ "$(cat "$T/locked.txt")" = "locked written" ]; then
  ok "a 0444 file takes a write"
else
  fail "a 0444 file refuses a write"
fi
if [ "$FROZEN" = 1 ]; then
  if printf ' written' >> "$F/immutable.txt" 2>/dev/null && [ "$(cat "$F/immutable.txt")" = "frozen
 written" ]; then ok "an immutable file takes a write"; else fail "an immutable file refuses a write"; fi
  if printf 'replaced\n' > "$F/append.txt" 2>/dev/null && [ "$(cat "$F/append.txt")" = "replaced" ]; then
    ok "an append-only file is overwritten"; else fail "an append-only file refuses an overwrite"; fi
fi

before="$("$WORK/finder-windows")"
finder_delete() {
  local err
  err="$(osascript -e 'on run argv' -e 'tell application "Finder"' -e 'with timeout of 120 seconds' \
    -e 'delete (POSIX file (item 1 of argv) as alias)' -e 'end timeout' -e 'end tell' -e 'end run' "$1" 2>&1 >/dev/null)"
  if [ -z "$err" ] && [ ! -e "$1" ]; then ok "Finder deletes ${1#"$point"/}"; else fail "Finder does not delete ${1#"$point"/}: ${err:-still there}"; fi
}
for d in sealed stamped readonly; do finder_delete "$T/$d/inside.txt"; done
if [ "$FROZEN" = 1 ]; then finder_delete "$F/immutable.txt"; finder_delete "$F/append.txt"; finder_delete "$F"; fi
finder_delete "$T"
dialogs=$(( $("$WORK/finder-windows") - before ))
if [ "$dialogs" -le 0 ]; then ok "no dialog"; else fail "$dialogs Finder windows opened"; fi
rm -rf "${point:?}/.Trashes/$(id -u)/$TREE"* "${point:?}/.Trashes/$(id -u)/lukotta-frozen"* 2>/dev/null

# Nothing of the owner's moved: every name and size two levels down is as it was,
# and the drive opens writable again, which a volume left dirty does not.
if [ -n "$owner_before" ]; then
  "$APP" --drive eject="$DEV" >/dev/null 2>&1; OPENED=0
  for _ in $(seq 1 120); do [ -z "$(served)" ] && break; sleep 1; done
  open_drive
  if mount | grep -F "$(basename "$DEV").local:" | grep -q 'read-only'; then
    fail "the drive opened read-only afterwards"
  else
    ok "the drive opens writable afterwards"
  fi
  if [ "$(owner_listing)" = "$owner_before" ]; then
    ok "everything else on the drive is as it was, $(printf '%s\n' "$owner_before" | wc -l) entries"
  else
    fail "entries outside this run changed:"
    diff <(printf '%s\n' "$owner_before") <(owner_listing) | head -20 | sed 's/^/         /'
  fi
fi

[ "$failed" = 0 ] && echo "every entry is writable" || echo "some entries are not writable"
[ "$failed" = 0 ]
