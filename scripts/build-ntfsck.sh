#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Builds ntfsck for the guest, so a damaged NTFS volume can be repaired here.
#
#   ./scripts/build-ntfsck.sh
#
# WHY THIS IS NEEDED
#
# `ntfsfix` is not a chkdsk and says so: it clears the dirty flag and fixes the
# boot sector. What an interrupted copy actually leaves is a directory index
# entry pointing at an MFT record that will not resolve, and on a real drive
# that name then refuses everything -- ls, stat, mv, rm, mkdir, all EIO, under
# both drivers. Measured on hardware on 2026-09-04. Nothing in Alpine repairs
# it: the distribution packages ntfs-3g and its progs and no checker at all.
#
# ntfsprogs-plus is a fork of those utilities whose whole purpose is `ntfsck`,
# "a filesystem checking utility comparable to Windows' chkdsk". Among its
# passes are the two this fault is made of: checking index entries, and scanning
# for orphaned MFT records. GPLv2, actively developed.
#
# DOCKER IS THE BUILD ENVIRONMENT, NOT A DEPENDENCY
#
# Nobody using Lukotta needs it. This produces one 1.6 MB aarch64 musl binary
# that is vendored into the guest image beside ntfsfix, exactly as the rest of
# the NTFS tools already are -- and building the engine already needs Rust, llvm
# and lld that no user installs either. The container is Alpine 3.24 on arm64
# because that is what the guest is, so the binary is built against the same
# libc it will run on.
#
# Skipping this is allowed. vendor-engine.sh ships whatever is there and the app
# falls back to ntfsfix alone, which is what it did before.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1
OUT="$HERE/vendor/engine-built"
REPO="${NTFSCK_REPO:-https://github.com/ntfsprogs-plus/ntfsprogs-plus}"

command -v docker >/dev/null 2>&1 || {
  echo "error: docker is needed to build this, and only to build it" >&2
  echo "       the app itself never needs it" >&2
  exit 2
}
docker version >/dev/null 2>&1 || {
  echo "error: docker is installed but its daemon is not running" >&2
  exit 2
}

mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Building ntfsck for the guest (Alpine 3.24, aarch64, musl)…"
docker run --rm --platform linux/arm64 -v "$WORK:/out" alpine:3.24 sh -c "
set -e
apk add --no-cache build-base autoconf automake libtool util-linux-dev \
  libgcrypt-dev git pkgconf linux-headers >/dev/null
git clone --depth 1 '$REPO' /src >/dev/null 2>&1
cd /src
git log --oneline -1 > /out/ntfsck.revision
./autogen.sh >/dev/null 2>&1
# Static, because the guest is trimmed and carries no build-time libraries: a
# binary that needs libgcrypt at runtime is a binary that does not run there.
./configure --disable-shared --enable-static --prefix=/usr >/dev/null 2>&1
make -j\"\$(nproc)\" >/dev/null 2>&1
cp \"\$(find . -name ntfsck -type f | head -1)\" /out/ntfsck
" 2>&1 | tail -3

[ -f "$WORK/ntfsck" ] || { echo "error: the build produced no ntfsck" >&2; exit 1; }
cp "$WORK/ntfsck" "$OUT/ntfsck"
cp "$WORK/ntfsck.revision" "$OUT/ntfsck.revision" 2>/dev/null || true
chmod 0755 "$OUT/ntfsck"
printf 'ntfsck from %s\n  %s\n  %s bytes\n' "$REPO" \
  "$(cat "$OUT/ntfsck.revision" 2>/dev/null || echo 'revision not recorded')" \
  "$(wc -c < "$OUT/ntfsck" | tr -d ' ')"
