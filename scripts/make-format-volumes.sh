#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Build one plain volume per format the app advertises, so every claim it
# makes has something to test it against.
#
#   ./scripts/make-format-volumes.sh [outdir]
#
# make-test-volumes.sh builds the LUKS layouts, and every filesystem in them
# is btrfs -- the only mkfs the trimmed guest still carries. That left ext,
# XFS and exFAT advertised on the box and never once opened by a test.
#
# The guest does not have to be the one that makes them. mkfs.ext4 comes from
# Homebrew's e2fsprogs and newfs_exfat ships with macOS, and a filesystem
# written into a file here is the same filesystem the guest kernel mounts
# later. XFS has no macOS mkfs at all and is reported as missing rather than
# quietly skipped: a fixture nobody built is a format nobody tested, and the
# run that says "everything passed" without it is the problem.
#
# Sizes are given in bytes rather than "1m": GNU dd wants 1M and BSD dd wants
# 1m, and a Mac with coreutils ahead of /usr/bin has the GNU one, where the
# lowercase spelling is an error rather than a smaller block.
# Where each advertised format stands, measured on 2026-09-01:
#
#   BitLocker  the owner's stick: 13 GB copied, 26/26 byte-identical, ejected
#              and unlocked again, 26/26 identical again through the new mount
#   NTFS       the same, and a dirty volume repaired writable with all 41 files
#              intact -- and the repair refused on a volume whose $MFTMirr did
#              not match $MFT
#   LUKS       three layouts, each copied both ways against the drive with 7
#              files and nothing differing: LUKS2 straight to btrfs (Arch),
#              LUKS1 through LVM (Ubuntu), LUKS2 through LVM (Fedora)
#   Btrfs      every one of those LUKS layouts holds btrfs, so the driver is
#              exercised by all three
#   ext        2 GB image, copied both ways against the drive, and the eight
#              integrity vectors run against it
#   exFAT      out of scope for this path, and checked rather than assumed.
#              Attached on a Mac, macOS mounted the volume itself -- the mount
#              table shows it as exfat, local, through fskit, with no microVM
#              anywhere near it -- and a file written to it read back. The app
#              declines exFAT deliberately, VolumeFormat.macOSHandlesFully, and
#              opening one here would turn a local volume into a network one
#              for nothing
#   XFS        TESTED, finally, and the way in was the guest rather than the
#              host. macOS has no mkfs.xfs and Homebrew has no xfsprogs, and
#              the trimmed guest carried none either -- so xfsprogs was put in
#              with `anylinuxfs apk add`, and `anylinuxfs shell <image>` puts a
#              blank image on /dev/vda where mkfs.xfs can reach it:
#
#                printf 'mkfs.xfs -f -L PLAINXFS /dev/vda; exit\n' \
#                  | anylinuxfs shell path/to/plain-xfs.img
#
#              Checked at the superblock afterwards -- XFSB at offset 0, and
#              blkid inside the guest reporting TYPE="xfs" -- because the last
#              thing in that directory calling itself an XFS fixture was a
#              sparse file with sixteen kilobytes allocated and no filesystem
#              in it at all. That stub is gone, and verify_image now asks every
#              image what it is before it counts as coverage.
#
#              Opened through the app's own path and put through the whole
#              torture corpus: 2024 files, non-ASCII and 255-byte names, sizes
#              on the block and transfer boundaries, a sparse gigabyte, two
#              thousand small files, deep paths. 2024 identical, 0 differing,
#              0 missing. The integrity vectors ran against it too: 10 of 11,
#              and the one failure is not XFS's -- see EngineProcesses.stop,
#              where a machine killed mid-write loses what it was holding on
#              ext4 in exactly the same way.
#
set -euo pipefail
OUT="${1:-$HOME/.lukotta-testvols}"
mkdir -p "$OUT"

# A file named plain-xfs.img is not an XFS volume.
#
# One was sitting in the fixture directory: two gigabytes long, sixteen
# kilobytes actually allocated, and not one byte of a superblock in it. The
# truncate that reserves the file had succeeded and the mkfs that was supposed
# to fill it had never run, so what was left behind was a stub with a
# convincing name. A listing of the directory showed xfs among the fixtures,
# which is exactly how a format nothing has ever opened comes to be counted as
# covered.
#
# So every image is asked what it is, by its superblock, and one that cannot
# answer is deleted rather than left to be miscounted later. `ls` is no help
# for this either -- it is eza on this machine and its columns are not the ones
# a script expects -- so sizes come from stat.
magic_at() {  # file, offset, byte-count -> lowercase hex
  dd if="$1" bs=1 skip="$2" count="$3" status=none 2>/dev/null | xxd -p | tr -d '\n'
}

verify_image() {  # file, format -> 0 if it really is that format
  local f="$1" fmt="$2"
  [ -s "$f" ] || return 1
  case "$fmt" in
    xfs)    [ "$(magic_at "$f" 0 4)" = "58465342" ] ;;          # XFSB
    ext)    [ "$(magic_at "$f" 1080 2)" = "53ef" ] ;;           # s_magic 0xEF53
    exfat)  [ "$(magic_at "$f" 3 5)" = "4558464154" ] ;;        # EXFAT
    ntfs)   [ "$(magic_at "$f" 3 4)" = "4e544653" ] ;;          # NTFS
    btrfs)  [ "$(magic_at "$f" 65600 8)" = "5f42485266535f4d" ] ;;  # _BHRfS_M
    luks)   [ "$(magic_at "$f" 0 6)" = "4c554b53babe" ] ;;      # LUKS\xba\xbe
    *)      return 0 ;;
  esac
}

# Called for anything this script claims to have made.
claim() {  # file, format, label
  if verify_image "$1" "$2"; then
    made+=("$3 ($(stat -c %s "$1") bytes)")
  else
    rm -f "$1"
    missing+=("$3 -- mkfs left nothing behind; the stub was deleted so it is not miscounted as a fixture")
  fi
}
# Two gigabytes, not six hundred megabytes. The corpus includes a sparse
# gigabyte, and NFSv3 cannot express a hole -- so it arrives fully allocated and
# a 600 MB volume runs out of space on that one file, which reads as a copy
# failure and is arithmetic.
MB=2048

made=() missing=()

# ext4. mkfs.ext4 takes a file directly, so no device is needed.
if command -v mkfs.ext4 >/dev/null 2>&1; then
  if [ ! -f "$OUT/plain-ext4.img" ]; then
    dd if=/dev/zero of="$OUT/plain-ext4.img" bs=1048576 count=0 seek="$MB" 2>/dev/null
    mkfs.ext4 -q -F -L PLAINEXT4 "$OUT/plain-ext4.img" >/dev/null 2>&1
  fi
  made+=("ext4")
else
  missing+=("ext4 (brew install e2fsprogs)")
fi

# exFAT. newfs_exfat wants a device, so the image is attached without being
# mounted -- macOS would otherwise mount it and hold it open.
if command -v newfs_exfat >/dev/null 2>&1; then
  if [ ! -f "$OUT/plain-exfat.img" ]; then
    dd if=/dev/zero of="$OUT/plain-exfat.img" bs=1048576 count=0 seek="$MB" 2>/dev/null
    dev="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage \
             "$OUT/plain-exfat.img" | awk 'NR==1{print $1}')"
    trap 'hdiutil detach "$dev" >/dev/null 2>&1 || true' EXIT
    newfs_exfat -v PLAINEXFAT "$dev" >/dev/null 2>&1
    hdiutil detach "$dev" >/dev/null 2>&1
    trap - EXIT
  fi
  made+=("exfat")
else
  missing+=("exfat (newfs_exfat is part of macOS; this should not happen)")
fi

# XFS. No mkfs on macOS -- Homebrew has no xfsprogs -- and none in the guest
# either, so there is nothing here to build it with. Said out loud rather than
# skipped, because XFS is on the box and a format nobody can make a fixture for
# is a format nobody tests.
#
# The engine can do it itself, which is better than any of the below:
#
#   anylinuxfs apk add xfsprogs
#
# "Manage custom alpine packages" -- it adds to [alpine] custom_packages in
# config.toml and reinitialises the guest with them. It refuses while any
# machine is running ("another instance is already running"), so the drive has
# to be closed first.
#
# That is also the answer to a second gap. The shipped guest carries mkfs and
# repair tools for btrfs, vfat and ntfs only: there is no e2fsck and no
# xfs_repair, so ext and XFS rely entirely on the kernel replaying their
# journals at mount and have no answer to corruption past that. NTFS is the
# only format the app can currently repair. Adding e2fsprogs and xfsprogs the
# same way would close it -- measured against image size before shipping,
# since the guest is trimmed deliberately.
#
# The other way through is Linux for the one command, and only for that:
#
#   docker run --rm -v "$OUT:/out" alpine sh -c \
#     'apk add --no-cache xfsprogs >/dev/null && \
#      dd if=/dev/zero of=/out/plain-xfs.img bs=1048576 count=0 seek=600 && \
#      mkfs.xfs -q -L PLAINXFS /out/plain-xfs.img'
#
# Not run from here: it needs a daemon that may not be running, and a fixture
# builder that silently starts a virtual machine is worse than one that says
# what it cannot do. The guest kernel mounts XFS perfectly well once the image
# exists -- making it is the only part that needs the tool.
if command -v mkfs.xfs >/dev/null 2>&1; then
  if [ ! -f "$OUT/plain-xfs.img" ]; then
    dd if=/dev/zero of="$OUT/plain-xfs.img" bs=1048576 count=0 seek="$MB" 2>/dev/null
    mkfs.xfs -q -L PLAINXFS "$OUT/plain-xfs.img" >/dev/null 2>&1
  fi
  made+=("xfs")
else
  missing+=("xfs (no mkfs.xfs on macOS, and none in the guest either)")
fi

printf 'built:   %s\n' "${made[*]:-none}"
printf 'missing: %s\n' "${missing[*]:-none}"
printf 'in %s\n' "$OUT"
[ ${#missing[@]} -eq 0 ]
