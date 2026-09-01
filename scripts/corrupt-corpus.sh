#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# What the app does when handed a genuinely broken NTFS volume.
#
#   ./scripts/corrupt-corpus.sh [corpus-dir] [limit]
#
# The repair tests until now made a volume dirty the honest way -- by killing
# the machine mid-write -- which produces one kind of damage. The ntfsprogs-plus
# people publish a corpus of about eighty NTFS images broken deliberately and
# specifically: boot sectors with impossible geometry, MFT records missing their
# data attribute, corrupted attribute lists, orphaned inodes, cluster runs
# pointing past the end of the disk, and a usb_unplug_test taken from a real
# unplug. It is GPL-2 and it is not vendored here; this clones it on demand.
#
#     https://github.com/ntfsprogs-plus/ntfs_corrupted_images
#
# Each image goes through the app's own ladder -- ntfs3, then ntfs-3g, then the
# repair action -- and two things are recorded: what happened, and whether the
# image changed.
#
# The second is the one that matters. "Repaired it" and "refused it" are both
# acceptable answers; the goal asks for repair and a refusal is at least safe.
# What is not acceptable is writing to a volume it could not understand, so a
# run that ends in refusal must leave the image byte-identical. That is checked
# rather than assumed, because a driver that scribbles on a damaged filesystem
# before giving up is how a recoverable disk becomes an unrecoverable one.
#
# AND IT FOUND THREE, WHICH IS THE POINT OF HAVING WRITTEN IT
#
# Of the first 27 cases: 17 mounted, 7 were refused and left untouched, and
# three were refused *and modified*:
#
#   created_manually/mft_file_missing_bitmap_attr
#   created_manually/mft_file_missing_data_attr
#   created_manually/mft_file_missing_filename_attr
#
# All three are MFT records missing an attribute -- structural damage, not a
# dirty flag. The obvious suspect was the repair action, since it runs ntfsfix
# and the engine's own documentation warns that using ntfsfix to clear a dirty
# flag "can lead to further data corruption". That was written down here as the
# strong reading, and it was wrong.
#
# Measured rung by rung instead -- hash the image, try ntfs3, hash, try
# ntfs-3g, hash, try the repair, hash -- on all three cases:
#
#   ntfs3     refused   image CHANGED
#   ntfs-3g   refused   image unchanged
#   repair    refused   image unchanged
#
# Identical on all three. It is not ntfsfix and it is not the repair route at
# all. **The kernel ntfs3 driver writes to a damaged volume during a mount it
# then refuses**, on the very first rung, before anything of ours has decided
# to attempt a repair.
#
# Which is the same driver the engine declines to make its default, for stated
# reasons: silent corruption on hibernated volumes, and read-only directories
# on Windows system disks. This app leads with ntfs3 because it is markedly
# faster. On a healthy volume that is the right trade. On a damaged one the
# first thing that happens is a write, to a disk somebody may have brought here
# precisely because it is damaged.
#
# ntfsck, from ntfsprogs-plus, is a real checker rather than a flag-clearer and
# would let the ladder know which kind of volume it has before touching it.
# GPL-2, aggregating in the guest like the rest of the userspace.
set -uo pipefail

CORPUS="${1:-}"
LIMIT="${2:-0}"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Dev.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
[ -x "$ENGINE" ] || { echo "error: no engine at $ENGINE" >&2; exit 2; }
APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
  "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo com.lukotta)"
export ANYLINUXFS_HOME="$HOME/Library/Application Support/$APP_ID/engine"

WORK="$(mktemp -d)"
IMG="$WORK/case.img"
cleanup() { pkill -f "anylinuxfs mount.*case" >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

if [ -z "$CORPUS" ]; then
  CORPUS="$WORK/corpus"
  echo "cloning the corrupted-image corpus…"
  git clone --depth 1 https://github.com/ntfsprogs-plus/ntfs_corrupted_images.git \
    "$CORPUS" >/dev/null 2>&1 || { echo "error: could not clone the corpus" >&2; exit 2; }
fi

where() {
  mount | awk '$1 ~ /case-img\.local:/ {for(i=1;i<=NF;i++) if($i=="on") {print $(i+1); exit}}'
}

# One attempt, with whatever driver and action the ladder is up to.
try_open() {
  pkill -f "anylinuxfs mount.*case" >/dev/null 2>&1; sleep 2
  # stdin from /dev/null, not inherited. The engine reads it, and inheriting
  # the loop's stdin let it swallow the list of cases being fed in through
  # process substitution: the first case ran, the rest were eaten, and the run
  # reported "cases 1" as though the corpus held one image.
  nohup "$ENGINE" mount --ignore-permissions -w false "$@" "$IMG" \
    > "$WORK/engine.log" 2>&1 < /dev/null &
  for _ in $(seq 1 25); do [ -n "$(where)" ] && return 0; sleep 2; done
  return 1
}

close_it() {
  local v; v="$(where)"
  [ -n "$v" ] && umount -f "$v" >/dev/null 2>&1
  pkill -f "anylinuxfs mount.*case" >/dev/null 2>&1
  sleep 2
}

mounted=0; repaired=0; refused=0; scribbled=0; n=0
printf '%-46s %-26s %s\n' "CASE" "OUTCOME" "IMAGE"
printf '%-46s %-26s %s\n' "----" "-------" "-----"

while IFS= read -r archive; do
  [ "$LIMIT" -gt 0 ] && [ "$n" -ge "$LIMIT" ] && break
  case_name="$(dirname "${archive#"$CORPUS"/}")"
  rm -f "$IMG"
  tar xJf "$archive" -C "$WORK" 2>/dev/null || continue
  found="$(find "$WORK" -maxdepth 1 -name '*.img' ! -name 'case.img' | head -1)"
  [ -n "$found" ] || continue
  mv "$found" "$IMG"
  n=$((n + 1))

  before="$(shasum -a 256 "$IMG" | awk '{print $1}')"
  outcome="refused"
  if try_open -t ntfs3 -a lukottatuned; then outcome="mounted (ntfs3)"
  else
    close_it
    if try_open -t ntfs-3g -a lukottatuned; then outcome="mounted (ntfs-3g)"
    else
      close_it
      if try_open -t ntfs3 -a lukottarepair; then outcome="mounted after repair"
      fi
    fi
  fi
  close_it
  after="$(shasum -a 256 "$IMG" | awk '{print $1}')"
  changed=same; [ "$before" != "$after" ] && changed=CHANGED

  case "$outcome" in
    refused)
      refused=$((refused + 1))
      # A refusal that wrote to the volume is the one bad answer here.
      [ "$changed" = CHANGED ] && { scribbled=$((scribbled + 1)); changed="CHANGED (refused, yet written to)"; } ;;
    "mounted after repair") repaired=$((repaired + 1)) ;;
    *) mounted=$((mounted + 1)) ;;
  esac
  printf '%-46s %-26s %s\n' "$case_name" "$outcome" "$changed"
done < <(find "$CORPUS" -name '*.img.tar.xz' | sort)

echo
printf 'cases %s: mounted %s, repaired %s, refused %s\n' "$n" "$mounted" "$repaired" "$refused"
printf 'refusals that wrote to the volume anyway: %s\n' "$scribbled"
[ "$scribbled" -eq 0 ]
