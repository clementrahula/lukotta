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
APP="${LUKOTTA_E2E_APP:-/Applications/Lukotta.app}"
CACHE="${LUKOTTA_E2E_CACHE:-$HOME/Library/Caches/dev.lukotta.e2e}"
CONTAINER="$CACHE/container.img"
PASSPHRASE="lukotta-e2e"

[ -d "$APP" ] || { echo "error: no app at $APP" >&2; exit 1; }
BINARY="$APP/Contents/MacOS/$(basename "$APP" .app)"
ENGINE="$APP/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs"

if [ ! -f "$CONTAINER" ]; then
  echo "==> Building a LUKS container to test against (once)"
  mkdir -p "$CACHE"
  # Large enough for a filesystem: btrfs refuses anything under about 110 MB.
  dd if=/dev/zero of="$CONTAINER" bs=1m count=0 seek=320 2>/dev/null
  "$ENGINE" shell "$CONTAINER" -c "
    echo -n '$PASSPHRASE' | cryptsetup luksFormat --type luks2 --batch-mode /dev/vda -
    echo -n '$PASSPHRASE' | cryptsetup luksOpen /dev/vda c -
    mkfs.btrfs -f -q -L LUKOTTAE2E /dev/mapper/c
    mkdir -p /mnt/t && mount /dev/mapper/c /mnt/t
    echo 'written by the end-to-end test' > /mnt/t/readme.txt
    umount /mnt/t
    cryptsetup luksClose c" >/dev/null 2>&1
  # A container with no LUKS header would make every run fail for the wrong
  # reason, so it is checked before anything depends on it.
  if ! head -c 4 "$CONTAINER" | grep -q LUKS; then
    rm -f "$CONTAINER"
    echo "error: the container was not created" >&2
    exit 1
  fi
fi

# Anything left attached from a run that was interrupted, so a stale device
# does not make this one pass or fail for the wrong reason.
while read -r device; do
  [ -n "$device" ] && hdiutil detach "$device" -force >/dev/null 2>&1 || true
done < <(hdiutil info 2>/dev/null | awk -v c="$CONTAINER" '
  /^image-path/ { path = $3 }
  /^\/dev\/disk[0-9]+\t/ { if (path == c) print $1 }')

"$BINARY" --e2e "$CONTAINER" "$PASSPHRASE"
