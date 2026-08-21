#!/bin/bash
# Drive a whole flow through the built app: open a container file, unlock it,
# rebuild the list underneath it, eject it.
#
#   ./scripts/e2e.sh
#
# Needs Full Disk Access for the app and a registered helper, so it runs on a
# real Mac rather than in CI. Nothing is drawn — the app exits before its window
# is ever built — and nothing of the user's is touched: the container is made
# here, in a cache of its own, and only that is opened.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# `anylinuxfs shell` truncates the image file to the last byte written, so an
# image comes back shorter than it went in — 320 MB in, 69 MB out — and the
# filesystem inside it then records one size and finds another, and refuses to
# mount. Putting the length back afterwards is enough: the tail was zeroes.
restore_length() {
  /usr/bin/python3 -c 'import os,sys; os.truncate(sys.argv[1], int(sys.argv[2]))' "$1" "$2"
}
SIZE=$((320 * 1024 * 1024))
APP="${LUKOTTA_E2E_APP:-/Applications/Lukotta.app}"
CACHE="${LUKOTTA_E2E_CACHE:-$HOME/Library/Caches/dev.lukotta.e2e}"
CONTAINER="$CACHE/container.img"
PLAIN="$CACHE/plain.img"
EXFAT="$CACHE/exfat.img"
QCOW_PLAIN="$CACHE/plain.qcow2"
QCOW_ENC="$CACHE/container.qcow2"
PASSPHRASE="lukotta-e2e"

[ -d "$APP" ] || { echo "error: no app at $APP" >&2; exit 1; }
BINARY="$APP/Contents/MacOS/$(basename "$APP" .app)"
ENGINE="$APP/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs"

if [ ! -f "$CONTAINER" ]; then
  echo "==> Building a LUKS container to test against (once)"
  mkdir -p "$CACHE"
  # Fully allocated, not sparse. A sparse image is one size when the
  # filesystem is made in it and another afterwards, and btrfs records the
  # first and refuses to mount against the second:
  #   device total_bytes should be at most 72548352 but found 335544320
  # Large enough for a filesystem too: btrfs refuses anything under ~110 MB.
  dd if=/dev/zero of="$CONTAINER" bs=1m count=320 2>/dev/null
  "$ENGINE" shell "$CONTAINER" -c "
    echo -n '$PASSPHRASE' | cryptsetup luksFormat --type luks2 --batch-mode /dev/vda -
    echo -n '$PASSPHRASE' | cryptsetup luksOpen /dev/vda c -
    mkfs.btrfs -f -q -L LUKOTTAE2E /dev/mapper/c
    mkdir -p /mnt/t && mount /dev/mapper/c /mnt/t
    echo 'written by the end-to-end test' > /mnt/t/readme.txt
    umount /mnt/t
    cryptsetup luksClose c" >/dev/null 2>&1
  restore_length "$CONTAINER" "$SIZE"
  # A container with no LUKS header would make every run fail for the wrong
  # reason, so it is checked before anything depends on it.
  if ! head -c 4 "$CONTAINER" | grep -q LUKS; then
    rm -f "$CONTAINER"
    echo "error: the container was not created" >&2
    exit 1
  fi
fi

if [ ! -f "$PLAIN" ]; then
  echo "==> Building an unencrypted image to test against (once)"
  mkdir -p "$CACHE"
  dd if=/dev/zero of="$PLAIN" bs=1m count=320 2>/dev/null
  "$ENGINE" shell "$PLAIN" -c "mkfs.btrfs -f -q -L LUKOTTAPLAIN /dev/vda" >/dev/null 2>&1
  restore_length "$PLAIN" "$SIZE"
fi

if [ ! -f "$EXFAT" ]; then
  echo "==> Building an exFAT image to test against (once)"
  mkdir -p "$CACHE"
  # A raw image and newfs_exfat, not `hdiutil create -fs ExFAT`: that answers
  # "Operation not permitted" here, and this shape is the one that matters
  # anyway — a filesystem with no partition table around it.
  dd if=/dev/zero of="$EXFAT" bs=1m count=40 2>/dev/null
  dev="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$EXFAT" | head -1 | awk '{print $1}')"
  newfs_exfat -v EXFAT "$dev" >/dev/null 2>&1
  hdiutil detach "$dev" -force >/dev/null 2>&1
fi

# qcow2 wrappers around the two images above. There is no qemu-img on a Mac,
# so the test writes its own; a linear mapping is what a converted image looks
# like anyway.
[ -f "$QCOW_PLAIN" ] || "$HERE/scripts/make-qcow2.py" "$PLAIN" "$QCOW_PLAIN" >/dev/null
[ -f "$QCOW_ENC" ] || "$HERE/scripts/make-qcow2.py" "$CONTAINER" "$QCOW_ENC" >/dev/null

# Anything left attached from a run that was interrupted, so a stale device
# does not make this one pass or fail for the wrong reason.
while read -r device; do
  [ -n "$device" ] && hdiutil detach "$device" -force >/dev/null 2>&1 || true
done < <(hdiutil info 2>/dev/null | awk -v c="$CONTAINER" -v p="$PLAIN" -v e="$EXFAT" '
  /^image-path/ { path = $3 }
  /^\/dev\/disk[0-9]+\t/ { if (path == c || path == p || path == e) print $1 }')

"$BINARY" --e2e "$CONTAINER" "$PASSPHRASE" "$PLAIN" "$EXFAT" "$QCOW_PLAIN" "$QCOW_ENC"
