#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# The patch that keeps a read-only folder deletable is in the kernel build and still applies.
#   ./scripts/read-only-attribute-patched.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
cd "$(dirname "$0")/.." || exit 2
PATCH="patches/linux-ntfs3-read-only-is-not-undeletable.patch"
KERNEL="$(awk -F'"' '/^KERNEL="/ {print $2; exit}' scripts/build-guest-kernel.sh)"
TARBALL="vendor/.cache/$KERNEL.tar.xz"

[ -f "$PATCH" ] || { echo "no $PATCH"; exit 1; }
# Named, not globbed, by the build: a patch it does not name is not built in.
grep -q "$(basename "$PATCH")" scripts/build-guest-kernel.sh \
  || { echo "$PATCH is not in OWN_PATCHES, so the build leaves it out"; exit 1; }
[ -f "$TARBALL" ] || { echo "no $TARBALL to check against; run ./scripts/build-guest-kernel.sh once"; exit 2; }

WORK="$(mktemp -d)"
trap '/bin/rm -rf "$WORK"' EXIT
tar -xJf "$TARBALL" -C "$WORK" "$KERNEL/fs/ntfs3/inode.c" || { echo "could not unpack ntfs3 from $TARBALL"; exit 2; }
# Applied the way the build applies it, fuzz and all, so a rebase upstream that
# moves the lines fails here rather than minutes into a kernel build.
out="$(patch -p1 --fuzz=0 --dry-run -d "$WORK/$KERNEL" < "$PATCH" 2>&1)"
rc=$?
printf '%s\n' "$out" | sed 's/^/  /'
[ "$rc" = 0 ] || { echo "$PATCH no longer applies to $KERNEL"; exit 1; }
# The mode keeps its write bits: the attribute is still read, and no longer
# decides what the owner of the mount may delete.
grep -q '^-.*mode &= ~0222;' "$PATCH" \
  || { echo "$PATCH no longer removes the line that clears the write bits"; exit 1; }
echo "applies to $KERNEL and is built in"
