#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# The patch that serves every entry readable and writable is in the kernel build and still applies.
#   ./scripts/every-entry-patch-applies.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
cd "$(dirname "$0")/.." || exit 2
PATCH="patches/linux-every-entry-is-writable.patch"
KERNEL="$(awk -F'"' '/^KERNEL="/ {print $2; exit}' scripts/build-guest-kernel.sh)"
TARBALL="vendor/.cache/$KERNEL.tar.xz"

[ -f "$PATCH" ] || { echo "no $PATCH"; exit 1; }
[ "$(grep -c "$(basename "$PATCH")" scripts/build-guest-kernel.sh)" -gt 0 ] \
  || { echo "$PATCH is not in OWN_PATCHES, so the build leaves it out"; exit 1; }
[ -f "$TARBALL" ] || { echo "no $TARBALL to check against; run ./scripts/build-guest-kernel.sh once"; exit 2; }

WORK="$(mktemp -d)"
trap '/bin/rm -rf "$WORK"' EXIT
tar -xJf "$TARBALL" -C "$WORK" "$KERNEL/fs/stat.c" "$KERNEL/fs/namei.c" "$KERNEL/fs/inode.c" \
  "$KERNEL/include/linux/fs.h" \
  || { echo "could not unpack $KERNEL"; exit 2; }
out="$(patch -p1 --fuzz=0 --dry-run -d "$WORK/$KERNEL" < "$PATCH" 2>&1)"
rc=$?
printf '%s\n' "$out" | sed 's/^/  /'
[ "$rc" = 0 ] || { echo "$PATCH no longer applies to $KERNEL"; exit 1; }
echo "applies to $KERNEL and is built in"
