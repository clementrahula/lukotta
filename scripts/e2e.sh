#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
# Drive a whole flow through the built app: open a container file, unlock it,
# rebuild the list underneath it, eject it.
#
#   ./scripts/e2e.sh
#
# Needs Full Disk Access for the app and a registered helper, so it runs on a
# real Mac rather than in CI. Nothing is drawn, the app exiting before its window
# is built, and nothing belonging to the user is touched: the container is made
# here in a cache of its own, and only that is opened.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# `anylinuxfs shell` truncates the image file to the last byte written, so an
# image returns shorter than it went in, 320 MB becoming 69 MB. The filesystem
# inside then records one size, finds another, and refuses to mount. Restoring
# the length afterwards is enough, the tail having been zeroes.
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
  # Fully allocated rather than sparse. A sparse image is one size when the
  # filesystem is made in it and another afterwards; btrfs records the first and
  # refuses to mount against the second:
  #   device total_bytes should be at most 72548352 but found 335544320
  # Also large enough for a filesystem: btrfs refuses anything under ~110 MB.
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
  # A raw image and newfs_exfat rather than `hdiutil create -fs ExFAT`, which
  # answers "Operation not permitted" here. This is also the shape that matters:
  # a filesystem with no partition table around it.
  dd if=/dev/zero of="$EXFAT" bs=1m count=40 2>/dev/null
  dev="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$EXFAT" | head -1 | awk '{print $1}')"
  newfs_exfat -v EXFAT "$dev" >/dev/null 2>&1
  hdiutil detach "$dev" -force >/dev/null 2>&1
fi

# qcow2 wrappers around the two images above. There is no qemu-img on a Mac, so
# the test writes its own, and a linear mapping is what a converted image looks
# like.
[ -f "$QCOW_PLAIN" ] || "$HERE/scripts/make-qcow2.py" "$PLAIN" "$QCOW_PLAIN" >/dev/null
[ -f "$QCOW_ENC" ] || "$HERE/scripts/make-qcow2.py" "$CONTAINER" "$QCOW_ENC" >/dev/null

# A monolithicFlat VMDK: a text descriptor beside a raw extent. The descriptor
# is read whole and capped at 2 MB, so the data cannot be stored inside it.
VMDK="$CACHE/plain.vmdk"
if [ ! -f "$VMDK" ]; then
  echo "==> Building a VMDK to test against (once)"
  cp "$PLAIN" "$CACHE/plain-flat.vmdk"
  sectors=$(( $(stat -f%z "$CACHE/plain-flat.vmdk") / 512 ))
  {
    printf '# Disk DescriptorFile\nversion=1\nCID=fffffffe\nparentCID=ffffffff\n'
    printf 'createType="monolithicFlat"\n\nRW %s FLAT "plain-flat.vmdk" 0\n\n' "$sectors"
    printf 'ddb.geometry.heads = "16"\nddb.geometry.sectors = "63"\n'
  } > "$VMDK"
fi

# And one whose descriptor reaches outside its own folder.
VMDK_BAD="$CACHE/reaches-out.vmdk"
[ -f "$VMDK_BAD" ] || printf '# Disk DescriptorFile\nversion=1\ncreateType="monolithicFlat"\n\nRW 4096 FLAT "/etc/passwd" 0\n' > "$VMDK_BAD"

# A fixed VHD is the raw disk followed by a 512-byte footer, which the engine
# reads unchanged. The dynamic form stores its data in blocks listed by an
# allocation table.
VHD="$CACHE/plain.vhd"
VHD_DYNAMIC="$CACHE/dynamic.vhd"
[ -f "$VHD" ] || "$HERE/scripts/make-vhd.py" "$PLAIN" "$VHD" >/dev/null
[ -f "$VHD_DYNAMIC" ] || "$HERE/scripts/make-vhd.py" "$PLAIN" "$VHD_DYNAMIC" --dynamic >/dev/null

# A VDI, VirtualBox's format: a header, a block map, and the blocks in the order
# they were written. Also one claiming version 0, which laid the header out
# differently and must be refused rather than read as version 1.
VDI="$CACHE/plain.vdi"
VDI_BAD="$CACHE/version-zero.vdi"
[ -f "$VDI" ] || "$HERE/scripts/make-vdi.py" "$PLAIN" "$VDI" >/dev/null
if [ ! -f "$VDI_BAD" ]; then
  head -c 512 "$VDI" > "$VDI_BAD"
  /usr/bin/python3 -c "
import sys
p = sys.argv[1]
b = bytearray(open(p, 'rb').read())
b[0x44:0x48] = (0).to_bytes(4, 'little')
open(p, 'wb').write(bytes(b))
" "$VDI_BAD"
fi

# A sparse VMDK: one file holding the header, the descriptor, a grain directory
# and the grains. Also one whose grains are deflated, which the driver reads
# through a separate path.
VMDK_SPARSE="$CACHE/sparse.vmdk"
[ -f "$VMDK_SPARSE" ] || "$HERE/scripts/make-vmdk-sparse.py" "$PLAIN" "$VMDK_SPARSE" >/dev/null
# The streamed form, whose grains are deflated and carry a marker each, and
# whose grain directory is at the end because it is written in one pass. Built
# here too, so the read path for it is exercised on any Mac rather than only
# where qemu-img happens to be installed.
VMDK_STREAMED="$CACHE/streamed.vmdk"
[ -f "$VMDK_STREAMED" ] || "$HERE/scripts/make-vmdk-streamed.py" "$PLAIN" "$VMDK_STREAMED" >/dev/null

# A VHDX: two headers, a region table, a metadata region and an allocation
# table. Also two that must be refused: one whose log was not
# emptied, so its most recent state was never written back into it, and one
# holding only the changes from a disk it names.
VHDX="$CACHE/plain.vhdx"
VHDX_DIRTY="$CACHE/dirty.vhdx"
VHDX_PARENT="$CACHE/differencing.vhdx"
[ -f "$VHDX" ] || "$HERE/scripts/make-vhdx.py" "$PLAIN" "$VHDX" >/dev/null
[ -f "$VHDX_DIRTY" ] || "$HERE/scripts/make-vhdx.py" "$PLAIN" "$VHDX_DIRTY" --dirty >/dev/null
[ -f "$VHDX_PARENT" ] || "$HERE/scripts/make-vhdx.py" "$PLAIN" "$VHDX_PARENT" --parent >/dev/null

# An image that names another file, which must be refused rather than opened.
HOSTILE="$CACHE/names-another-file.qcow2"
[ -f "$HOSTILE" ] || "$HERE/scripts/make-qcow2.py" --hostile "$HOSTILE" "$HOME/.ssh/id_rsa" >/dev/null

# Anything left attached from a run that was interrupted, so a stale device
# does not make this one pass or fail for the wrong reason.
while read -r device; do
  [ -n "$device" ] && hdiutil detach "$device" -force >/dev/null 2>&1 || true
done < <(hdiutil info 2>/dev/null | awk -v c="$CONTAINER" -v p="$PLAIN" -v e="$EXFAT" '
  /^image-path/ { path = $3 }
  /^\/dev\/disk[0-9]+\t/ { if (path == c || path == p || path == e) print $1 }')

# Whatever this run leaves behind goes with it, however it ends.
#
# A mount that failed leaves the engine's network helper running with nothing
# to eject it, and it holds the image file locked, so the next run finds every
# fixture in use and fails for a reason that has nothing to do with the code.
# The app takes down what a failed attempt started; this covers the rest,
# including a run killed part-way through.
clean_up() {
  status=$?
  while read -r point; do
    [ -n "$point" ] && umount "$point" >/dev/null 2>&1 || true
  done < <(/sbin/mount | awk '/ on .*\/Volumes\/LUKOTTA(E2E|PLAIN)/ && /nfs/ {
      sub(/^.* on /, ""); sub(/ \(.*$/, ""); print }')
  pkill -f "$APP/Contents/Resources/engine/anylinuxfs" >/dev/null 2>&1 || true
  return $status
}
trap clean_up EXIT

# Named, not positional. Adding a format is a line here and a line in
# EndToEnd.swift, rather than a count that has to agree on both sides.
"$BINARY" --e2e \
  container="$CONTAINER" \
  passphrase="$PASSPHRASE" \
  plain="$PLAIN" \
  exfat="$EXFAT" \
  qcow2="$QCOW_PLAIN" \
  qcow2-encrypted="$QCOW_ENC" \
  hostile="$HOSTILE" \
  vmdk="$VMDK" \
  vmdk-reaching="$VMDK_BAD" \
  vhd="$VHD" \
  vhd-dynamic="$VHD_DYNAMIC" \
  vdi="$VDI" \
  vdi-ancient="$VDI_BAD" \
  vmdk-sparse="$VMDK_SPARSE" \
  vmdk-streamed="$VMDK_STREAMED" \
  vhdx="$VHDX" \
  vhdx-dirty="$VHDX_DIRTY" \
  vhdx-parent="$VHDX_PARENT"
