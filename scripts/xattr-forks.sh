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
#   a resource fork             THE WHOLE FILE IS DROPPED
#
# The last line is not a lost attribute, it is a lost file. ditto writes its
# AppleDouble through a temp file, that write returns EINVAL, and nothing is
# created:
#
#   ditto: /Volumes/DRIVE/.BC.T_fKsndK: Invalid argument
#
# And the exit status depends on how the copy was asked for, which is the part
# that matters:
#
#   ditto forked.bin /Volumes/DRIVE/forked.bin   -> exit 1, file absent
#   ditto sourcedir/ /Volumes/DRIVE/dir/         -> exit 0, file absent
#
# One file at a time it at least reports the failure. Handed a directory --
# which is what copying a folder is -- it prints one line among however many
# others are scrolling past and exits 0, having quietly left a file behind. A
# copy that reports success and drops a file is the worst answer available, and
# Finder copies through the same machinery.
#
# So the files are checked here one at a time on purpose. A directory-wide
# ditto would have reported this as a pass.
#
# WHERE IT ACTUALLY FAILS, narrowed to one refused call
#
#   printf data > /Volumes/DRIVE/f.bin                   ok
#   printf x    > /Volumes/DRIVE/._f.bin                 ok, AppleDouble by hand
#   printf x    > /Volumes/DRIVE/f.bin/..namedfork/rsrc  not writable
#   xattr -w com.apple.ResourceFork ... f.bin            [Errno 22] EINVAL
#
# Every other extended attribute is accepted and stored beside the original.
# com.apple.ResourceFork alone is refused by the macOS NFS client, which is why
# ditto fails on exactly the files that have one and on no others. No mount
# option reaches this: it is the client, and the app has no lever on it. See
# upstream-notes.md -- virtiofs carries extended attributes natively.
#
# It is the NFS stack rather than the filesystem or the tool. The identical
# command with the identical file onto local APFS keeps the fork -- 16 bytes,
# readable at ..namedfork/rsrc -- and onto an XFS image over this same stack it
# fails exactly as it does on NTFS.
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
printf 'RESOURCEFORKDATA' > "$W/forked.bin/..namedfork/rsrc"

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
