#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
# Everything that says the v2 write path is right, in one run.
#
# Takes a copy of an NTFS image, does every kind of write to it, and then asks
# two questions of the result that this filesystem's own code cannot answer:
# what changed, and is the volume still consistent. Both are answered by
# programs written from the on-disk format rather than from this source.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 1

IMAGE="${1:-${LUKOTTA_NTFS_IMAGE:-}}"
if [ -z "$IMAGE" ] || [ ! -f "$IMAGE" ]; then
  printf 'usage: %s <ntfs-image>\n' "$0" >&2
  printf '  or set LUKOTTA_NTFS_IMAGE. Nothing is written to the image itself.\n' >&2
  exit 2
fi

WORK="$(mktemp -d)"
clean_up() { rm -rf "$WORK"; }
trap clean_up EXIT

COPY="$WORK/volume.img"
status=0

printf 'copying %s…\n' "$(basename "$IMAGE")"
cp "$IMAGE" "$COPY" || exit 1

printf '\nbuilding…\n'
swift build -c release >/dev/null 2>&1 || { printf 'error: the build failed\n' >&2; exit 1; }

printf '\nevery check, against the copy…\n'
if LUKOTTA_NTFS_IMAGE="$IMAGE" LUKOTTA_WRITE_IMAGE="$COPY" \
  .build/release/LukottaTests 2>&1 | tail -2; then :; else status=1; fi

printf '\nthirty rounds of four hundred, and a file written and removed…\n'
cp "$IMAGE" "$COPY"
if LUKOTTA_BENCH_ROUNDS=30 LUKOTTA_BENCH_FILES=400 LUKOTTA_BENCH_MB=64 \
  LUKOTTA_NTFS_IMAGE="$IMAGE" LUKOTTA_WRITE_IMAGE="$COPY" \
  .build/release/LukottaTests 2>&1 | grep -E 'created in|removed in|wrote|read |FAIL'; then :; fi

printf '\nwhat changed, in the volume'"'"'s own terms…\n'
scripts/volume-diff.py "$IMAGE" "$COPY" | tail -3

printf '\nand whether the volume is still consistent…\n'
if ! scripts/volume-check.py "$COPY"; then
  printf 'error: the volume did not come out consistent\n' >&2
  status=1
fi

if [ "$status" -eq 0 ]; then
  printf '\nThe writes hold up.\n'
else
  printf '\nSomething is wrong; the output above says what.\n' >&2
fi
exit "$status"
