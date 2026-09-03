#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# What a Mac attaches to a file, and what survives the crossing.
#
#   ./scripts/xattr-forks.sh <mount-point>
#
# Every file macOS hands over carries more than its bytes. Anything downloaded
# has com.apple.quarantine on it; anything tagged in Finder has
# com.apple.metadata:_kMDItemUserTags; older files still have a resource fork.
# NFSv3 has nowhere to put any of it, so the client writes AppleDouble "._"
# files beside the originals -- and that is where it gets interesting, because
# it works for some of these and not for others.
#
# Measured on 2026-09-01, against the owner's BitLocker drive and again against
# an XFS image, with a copy onto local APFS as the control:
#
#   com.apple.quarantine        survives, in ._quarantined.bin
#   com.apple.metadata tags     survives, in ._tagged.bin
#   a custom xattr              survives, in ._custom.bin
#   a resource fork             survives, all 286 bytes of it
#
# WITHDRAWN, 2026-09-03. Everything this said was the fixture.
#
# It read: a file carrying a resource fork is dropped entirely, ditto exits 0
# when handed a directory, the macOS NFS client refuses com.apple.ResourceFork,
# no mount option reaches it, and the app has no lever on it. None of that is
# true, and it was recorded here for two days as a known defect.
#
# The fixture wrote sixteen bytes -- "RESOURCEFORKDATA" -- into
# ..namedfork/rsrc and called it a resource fork. It is not one. macOS refuses
# to build an AppleDouble around it on ANY filesystem that needs one, and the
# same ditto fails identically on a plain local exFAT image with no NFS, no
# guest and none of this app anywhere near it:
#
#   ditto: /Volumes/FORKTEST/.BC.T_PKvT4i: Invalid argument
#
# With a structurally valid fork -- a 256-byte header and an empty resource map,
# which is what an empty fork is on disk -- the same copy onto the app's own
# mount keeps every byte:
#
#   valid fork  -> data 13 bytes, fork 286 bytes, on the app mount and on exFAT
#   invalid one -> Invalid argument, on the app mount and on exFAT alike
#
# So resource forks survive this app perfectly well, and what was measured was
# macOS declining to wrap sixteen arbitrary bytes in an AppleDouble. The lesson
# is the one this file was written to teach and then fell to itself: a fixture
# that is not what it claims to be produces a defect that is not there.
#
# `cp` behaves differently and no better: the file arrives, the data fork is
# byte-identical, and the resource fork is gone without a word.
set -uo pipefail
MNT="${1:-}"
[ -d "$MNT" ] || { echo "usage: $0 <mount-point>" >&2; exit 2; }

W="$(mktemp -d)"
DST="$MNT/xattr-forks-test"
trap 'rm -rf "$W"; rm -rf "$DST"' EXIT
rm -rf "$DST"; mkdir -p "$DST" || { echo "error: $MNT is not writable" >&2; exit 1; }

pass=0; fail=0
note() { if [ "$1" = ok ]; then pass=$((pass+1)); printf '  ok   %s\n' "$2";
         else fail=$((fail+1)); printf '  FAIL %s\n' "$2"; fi }

head -c 200000 /dev/urandom > "$W/quarantined.bin"
xattr -w com.apple.quarantine "0083;68b5c0a1;Safari;" "$W/quarantined.bin"
head -c 200000 /dev/urandom > "$W/custom.bin"
xattr -w com.example.note "hello" "$W/custom.bin"
head -c 200000 /dev/urandom > "$W/forked.bin"
# A structurally valid resource fork, not sixteen bytes called one.
#
# This wrote "RESOURCEFORKDATA" and concluded that a resource fork makes macOS
# drop the whole file. It does not. That string is not a resource fork, and
# macOS refuses to write an AppleDouble for it on ANY filesystem that needs one
# -- measured on a plain local exFAT image, with no NFS and none of this app
# involved, failing exactly the same way with exactly the same
# "ditto: .../.BC.T_xxxxxx: Invalid argument".
#
# With a real fork -- a 256-byte header and an empty resource map -- the same
# ditto onto the app's own mount keeps all 286 bytes. So the fault that was
# recorded here was the fixture, and everything downstream of it was wrong.
/usr/bin/python3 - "$W/forked.bin/..namedfork/rsrc" <<'RSRC'
import struct, sys
data_off, map_off, data_len, map_len = 256, 256, 0, 30
header = struct.pack(">IIII", data_off, map_off, data_len, map_len) + b"\0" * 240
rmap = struct.pack(">16sIHH", header[:16], 0, 0, 0)
rmap += struct.pack(">HH", 28, 30)
rmap += struct.pack(">h", -1)
open(sys.argv[1], "wb").write(header + rmap)
RSRC

# Copied one at a time: a single file that fails must not be hidden by the
# others succeeding, which is what a directory-wide ditto does.
for f in quarantined.bin custom.bin forked.bin; do
  err="$(ditto "$W/$f" "$DST/$f" 2>&1)"
  rc=$?
  if [ ! -e "$DST/$f" ]; then
    note no "$f arrives at all (ditto exit $rc${err:+, said: $err})"
    continue
  fi
  if cmp -s "$W/$f" "$DST/$f"; then note ok "$f arrives, bytes identical"
  else note no "$f arrives, but the bytes differ"; fi
done

# The attribute itself, not merely the file.
for f in quarantined.bin custom.bin; do
  [ -e "$DST/$f" ] || continue
  if [ -n "$(xattr "$DST/$f" 2>/dev/null)" ]; then
    note ok "$f keeps its extended attribute"
  else
    note no "$f keeps its extended attribute"
  fi
done

if [ -e "$DST/forked.bin" ]; then
  src_rsrc="$(stat -c %s "$W/forked.bin/..namedfork/rsrc" 2>/dev/null || echo 0)"
  dst_rsrc="$(stat -c %s "$DST/forked.bin/..namedfork/rsrc" 2>/dev/null || echo 0)"
  if [ "$src_rsrc" = "$dst_rsrc" ]; then note ok "the resource fork survives ($dst_rsrc bytes)"
  else note no "the resource fork survives (source $src_rsrc, destination $dst_rsrc)"; fi
fi

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
