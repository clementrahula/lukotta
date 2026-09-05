#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# The vectors a copy is not supposed to survive, run against a fixture.
#
#   ./scripts/integrity-vectors.sh <image> [engine]
#
# A copy that completes twice says nothing about what happens when it does
# not. These are the ways it does not: killed partway, unmounted underneath,
# run into a full volume, the machine killed outright with writes still in
# flight, and the same volume opened and closed repeatedly.
#
# Killing the copier and killing the machine are different accidents and only
# the first was covered here for a long time. With ditto killed the guest is
# alive and flushes what it holds; with the machine killed the guest dies with
# a page cache full of writes that never reached the image, and that is the
# accident that corrupts filesystems. The power-loss case has no result written
# below yet -- it has not been run.
# What is checked afterwards is not "did the copy finish" -- it did not, that
# is the point -- but whether the filesystem is still sound and whether the
# files that had already landed are still exactly themselves.
#
# RE-RUN 2026-09-02 on XFS, after the write size changed to 32768. Ten of
# eleven pass:
#
#   ok   a killed copy leaves no corrupt file behind (40 whole, 0 wrong)
#   ok   the volume still takes a write after a copy was killed
#   ok   the volume mounts and reads after being unmounted under load
#   ok   what was written before the unmount survived it
#   ok   a full volume answers with an error, in 7s
#   ok   three open/close cycles in a row (3 of 3)
#   ok   everything written is readable by whoever wrote it (3 of 3)
#   ok   two writers and a reader at once leave nothing wrong (24, 0 differing)
#   ok   the filesystem comes back after the machine was killed mid-write
#   FAIL every fsynced file survived power loss (8 of 8 present, 8 wrong)
#   ok   the volume takes a write again after power loss
#
# AND IT IS NOT ONLY IMAGE FILES. TESTED ON THE PHYSICAL DRIVE.
#
# The durability gap was measured on images, where the engine keeps a
# user-space cache of the image file, so it was reasonable to hope a real
# device -- passed through rather than backed by a file -- would not have it.
# It does, and worse.
#
# On the owner's BitLocker drive: 8 MB written with dd conv=fsync, which
# returns only once the client's COMMIT has been answered; dd exit 0; the
# machine then killed with SIGKILL. On reopening, the file is not there at
# all. On an image the same test returned a full-length file with holes; on
# the drive it returns nothing.
#
# So fsync is not a durability barrier against a killed machine on any storage
# this app serves. What the app can do about it, it does: EngineProcesses.stop
# waits up to twenty seconds for SIGTERM, which flushes, and never reaches for
# SIGKILL while a machine is still going. What remains exposed is a force
# quit, a crash, or the power going.
#
# The same run demonstrated the other half unattended: the kill left the volume
# dirty, and reopening it repaired it and mounted writable with every folder
# and file count unchanged and 28 of 28 sampled files readable. That is item
# seven working in the wild rather than on a fixture, for the second time.
#
# The failure is the known one and not a regression from the write size: the
# engine's disk backend makes writes durable when it shuts down rather than
# when a write is acknowledged, so a machine killed outright loses what it
# held however small the write unit was. That is what EngineProcesses.stop
# waits twenty seconds to avoid, and what a SIGKILL from outside still causes.
#
# Result on 2026-09-01, against a 64 MB NTFS fixture:
#
#   ok   a killed copy leaves no corrupt file behind (32 whole, 0 wrong)
#   ok   the volume still takes a write after a copy was killed
#   ok   the volume mounts and reads after being unmounted under load
#   ok   what was written before the unmount survived it
#   ok   a full volume answers with an error, in 1s
#   ok   three open/close cycles in a row
#
# The fixture ran out of space partway, which made the first case harsher than
# it was meant to be -- a copy killed on a volume that was already full -- and
# it still left nothing corrupt behind.
#
# Run again on a 2 GB ext4 image with permissions and concurrency added, all
# eight passing:
#
#   ok   a killed copy leaves no corrupt file behind (40 whole, 0 wrong)
#   ok   everything written is readable by whoever wrote it (3 of 3)
#   ok   two writers and a reader at once leave nothing wrong (24, 0 differing)
#
# The cycles case failed the first time at two of three, and that was this
# script being impatient rather than the app being wrong. Mounter.mount says
# it plainly: the machine keeps the image for another half-minute after the
# share goes, and opening the same file inside that window meets a locked file.
# The app waits for that. So does this now.
#
# Deliberately a fixture and never a real drive. Force-unmounting a volume
# mid-write is the operation most likely to damage it, and the drive somebody
# keeps their photographs on is not the place to find out. The image is made by
# make-format-volumes.sh or make-test-volumes.sh and holds nothing anybody
# needs.
set -uo pipefail

IMAGE="${1:-}"
# The same default as vectors-every-format.sh, which calls this. They
# disagreed: that one named the Beta build and this one a Dev build, and a
# Dev build is not compiled with devtools unless somebody asks -- so a run
# started directly here drove an app with no --drive and stopped before it
# opened anything. verify.sh now resolves an app that answers to --drive and
# passes it, which is the real fix; this is so the two agree when nobody does.
ENGINE="${2:-/Applications/Lukotta Beta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"

# A real drive, given as /dev/diskNsM, instead of an image.
#
# Everything here has only ever been asked of disk images, and a disk image
# cannot answer some of it: writes to one reach the backing file through the
# host's page cache, which survives the machine being killed, so the power-loss
# vectors are answered by macOS rather than by the drive. A real device has no
# such cache behind it -- which is where a committed write was first seen to go
# missing, and where the poisoned directory entry was first seen on hardware.
#
# On a device nothing is copied and nothing is formatted: the drive is used as
# it is, everything this writes lives under names of its own, and they are
# removed at the end.
DEVICE=""
case "$IMAGE" in
  /dev/*) DEVICE="$IMAGE" ;;
esac
if [ -n "$DEVICE" ]; then
  [ -b "$DEVICE" ] || [ -c "$DEVICE" ] || {
    echo "error: no device at $DEVICE" >&2; exit 2; }
  # A device is opened through the app, which is the only route that holds it:
  # /dev/diskNsM is root:operator and the privileged daemon passes the
  # descriptor over.
  THROUGH_APP=1
else
  [ -f "$IMAGE" ] || { echo "usage: $0 <image|/dev/diskNsM> [engine]" >&2; exit 2; }
fi
[ -x "$ENGINE" ] || { echo "error: no engine at $ENGINE" >&2; exit 2; }

APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
  "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo com.lukotta)"
export ANYLINUXFS_HOME="$HOME/Library/Application Support/$APP_ID/engine"

WORK="$(mktemp -d)"

# Every run gets its own copy of the fixture, and the original is never touched.
#
# These vectors write eighty megabytes, fill the volume to the last block, and
# kill the machine repeatedly. What they leave behind is not tidied by the next
# run's cleanup, because a kill can happen before an unlink reaches the image --
# so the run after this one starts on a volume that is part full, and the run
# after that on one with no room at all. Three separate failures were chased
# tonight that were exactly this: a volume whose operations timed out, an image
# holding three hundred megabytes of somebody's test files, and a copy that
# carried leftovers forward every time it was made.
#
# A copy costs a few seconds and a few hundred megabytes of temporary space,
# and buys a run that means the same thing every time.
if [ -n "$DEVICE" ]; then
  # Nothing to copy: the drive is the fixture. APP_DEV is what the app is
  # handed, and the partition-choosing below is skipped because the caller
  # named the partition.
  ORIGINAL="$DEVICE"
else
ORIGINAL="$IMAGE"
# The copy is named after this run's workspace, not after the original.
#
# The engine names its share from the image's file name, and `where` finds a
# mount by that name. Two runs of the same fixture therefore produce two shares
# called the same thing, and a mount left behind by a killed engine is matched
# by the next run -- which then measures the previous run's volume, full and
# already spoiled. That is what "52 MB free" was.
IMAGE="$WORK/$(basename "$ORIGINAL" .img)-$(basename "$WORK").img"

# What earlier runs left behind, before making one more.
#
# The copy is removed on a clean exit and a killed run keeps its 2.7 GB. Fifty
# such runs -- every interrupted sweep of a night's work -- put 178 GB into the
# temporary directory and filled a 461 GB disk to 100%. What that looked like
# was not "the disk is full": it was exFAT failing three integrity vectors it
# had passed an hour earlier, which is a fault in the app as far as anybody
# reading the output could tell. A harness that fills the disk invents failures
# in whatever runs next.
#
# So the copies from runs that did not finish are cleared first. They are
# recognisable: this is the only thing that names a file "<fixture>-tmp.*.img".
find "$(dirname "$WORK")" -maxdepth 2 -name '*-tmp.*.img' -mmin +5 -delete 2>/dev/null

# And the workspace it sat in, which this used to leave standing.
#
# Clearing the image alone left the corpora -- awkward, conc, src, mnt -- and
# they are most of it. Measured on 2026-09-05 after an evening of interrupted
# gates, with every image already swept by a later run: 348 workspaces still
# holding 52 GB, on a Mac with 23 GB free. The same fault as the one above,
# found the same way, half-fixed the first time.
#
# Recognised by the two corpus directories every workspace of this harness has,
# so nothing else in the temporary directory is touched, and only after an hour
# so a run happening right now beside this one is left alone.
find "$(dirname "$WORK")" -maxdepth 1 -type d -name 'tmp.*' -mmin +60 2>/dev/null \
  | while read -r old_work; do
      [ "$old_work" = "$WORK" ] && continue
      [ -d "$old_work/awkward" ] && [ -d "$old_work/conc" ] || continue
      rm -rf "$old_work" 2>/dev/null
    done

# And there has to be room for one. Refusing here says what is wrong; running
# anyway says the filesystem under test is broken.
need=$(( $(stat -c %s "$ORIGINAL" 2>/dev/null || echo 0) / 1048576 + 512 ))
free=$(df -m "$(dirname "$WORK")" | tail -1 | awk '{print $4}')
if [ "${free:-0}" -lt "$need" ]; then
  echo "error: ${free:-0} MB free where this needs ${need} MB; not starting" >&2
  echo "       a run that fills the disk reports the app as broken instead" >&2
  exit 2
fi

printf 'copying the fixture so this run cannot spoil the next one\n'
cp "$ORIGINAL" "$IMAGE" || { echo "error: could not copy $ORIGINAL" >&2; exit 2; }
fi
MNT="$WORK/mnt"; mkdir -p "$MNT"
trap 'cleanup' EXIT
cleanup() {
  umount -f "$MNT" >/dev/null 2>&1
  pkill -f "anylinuxfs mount.*$IMAGE" >/dev/null 2>&1
  rm -rf "$WORK"
}

# This image's mount, and only this one. Another volume may be open -- the
# owner's drive usually is -- so the last engine mount in the table is somebody
# else's, and a mount whose machine has been killed stays there answering
# `mount` and failing every request. The engine names a share after the file it
# came from, so that is what to look for.
where() {
  # The engine names a share after what it was handed. Given an image file that
  # is "<name>-img.local"; given a device -- which is what the app hands it --
  # it is "diskN.local". So the route decides the name to look for, and looking
  # for the wrong one reported "the engine never mounted it" about a mount that
  # had just succeeded and was sitting in the table.
  local want point
  if [ -n "${APP_DEV:-}" ]; then
    want="$(basename "$APP_DEV").local:"
  else
    want="$(basename "$IMAGE" .img)-img.local:"
  fi
  point="$(mount | awk -v want="$want" \
    '$1 ~ want {for(i=1;i<=NF;i++) if($i=="on") {print $(i+1); exit}}')"
  [ -n "$point" ] && { printf '%s\n' "$point"; return; }

  # A container of logical volumes is not named after what it was handed.
  #
  # An LVM group comes up as "lvm-<group>.local:" with each volume mounted
  # inside a parent, so looking for the device name found nothing and this said
  # "the engine never mounted it" about four fixtures whose groups had activated
  # and whose volumes were sitting in the table. The same mistake, in the same
  # words, as the helper's own check made about the same drives.
  #
  # The roomiest of them, not the deepest-named.
  #
  # The parent is a one-megabyte tmpfs holding the volumes, so it is never the
  # answer; among the volumes themselves the longest name is an arbitrary
  # choice, and on luks1-lvm it picked one with 139 MB free where the vectors
  # want 200 -- reported as a volume too small when a roomier one was mounted
  # beside it the whole time.
  # And the same one every time after that.
  #
  # Roomiest is the right way to choose once and the wrong way to choose twice.
  # This is called again after every reopen -- power loss, unmount under load,
  # repeated mount cycles -- and luks-multi has three logical volumes of equal
  # size whose data is cleared between vectors, so all three sit at the same
  # free space and the winner is settled by `-gt` keeping whichever the mount
  # table listed first. That order is not stable across a reopen.
  #
  # So the harness could write eight fsynced files into one volume, kill the
  # machine, reopen, and read a different one. An empty volume reads exactly
  # like total loss, and it was reported as one:
  #
  #     FAIL every fsynced file survived power loss (0 of 8, 8 lost)
  #     note 0 of 30 in-flight files came back at full length
  #
  # Absent rather than truncated, on multi-volume fixtures only, about one run
  # in eight -- the shape of a coin toss rather than of a filesystem. The name
  # is remembered in a file because this runs in a subshell, so an assignment
  # here would not outlive the call that made it.
  local candidates best bestfree free source kept
  kept="${CHOSEN_VOLUME:-$WORK/.chosen-volume}"
  # Remembered by the volume's own name, not by the whole share string. That
  # string carries the device -- lvm-fedoravg.local:/run/disk5s1/FEDORAHOME --
  # and hdiutil does not promise the same disk number on the next attach, so
  # keying on the whole thing would fail to find a volume that is sitting right
  # there and report the engine as never having mounted it.
  if [ -s "$kept" ]; then
    source="$(cat "$kept")"
    point="$(mount | awk -v s="/$source" \
      '$1 ~ /^lvm-[^ ]*\.local:/ && substr($1, length($1) - length(s) + 1) == s {
         for(i=1;i<=NF;i++) if($i=="on") {print $(i+1); exit}}')"
    [ -n "$point" ] && { printf '%s\n' "$point"; return; }
    # Gone from the table: the container was reopened and the volume is not
    # back. Say nothing rather than quietly reading a different one.
  fi
  candidates="$(mount | awk '$1 ~ /^lvm-[^ ]*\.local:/ {
                  for (i = 1; i <= NF; i++) if ($i == "on") print $(i + 1)
                }')"
  best=""; bestfree=-1
  for point in $candidates; do
    free="$(df -m "$point" 2>/dev/null | tail -1 | awk '{print $4}')"
    [ -n "${free:-}" ] || continue
    if [ "$free" -gt "$bestfree" ]; then bestfree="$free"; best="$point"; fi
  done
  if [ -n "$best" ]; then
    mount | awk -v p="$best" '{for(i=1;i<=NF;i++) if($i=="on" && $(i+1)==p) {print $1; exit}}' \
      | sed 's|.*/||' > "$kept" 2>/dev/null
    printf '%s\n' "$best"
  fi
}

open_image() {
  pkill -f "anylinuxfs mount.*$IMAGE" >/dev/null 2>&1; sleep 3
  # LUKOTTA_MOUNT_OPTIONS carries a filesystem mount option into the guest, so
  # a durability question can be asked of one setting at a time rather than by
  # hand. ext4 loses fsynced content here and NTFS does not, and data=journal is
  # the setting that would say whether ordered mode is the reason.
  OPTS=()
  [ -n "${LUKOTTA_MOUNT_OPTIONS:-}" ] && OPTS=(-o "$LUKOTTA_MOUNT_OPTIONS")
  # LUKOTTA_EXPORT_OPTS asks the same question of the other layer. A file
  # written and fsynced inside the guest survives the machine being killed --
  # 8 of 8, measured -- and the same file written over NFS does not, so what
  # the export promises is worth being able to vary.
  #
  # --nfs-export-opts replaces the engine's own template, and the engine
  # refuses it beside --ignore-permissions, so this replaces that flag rather
  # than joining it.
  # The macOS client's own mount options. A client mounted synchronous sends
  # its writes stable rather than unstable, and that is where the durability
  # fault turned out to live: 4 of 4 files kept with it, 0 of 4 without.
  [ -n "${LUKOTTA_NFS_OPTIONS:-}" ] && OPTS+=(--nfs-options="$LUKOTTA_NFS_OPTIONS")
  if [ -n "${LUKOTTA_EXPORT_OPTS:-}" ]; then
    OPTS+=(--nfs-export-opts="$LUKOTTA_EXPORT_OPTS")
  else
    OPTS+=(--ignore-permissions)
  fi
  # Through the app, when asked, because everything below this line is about
  # the storage path and nothing above it is about the app.
  #
  # Whether a file survived a power cut is a fact about the filesystem, the
  # guest and the flush path, and those do not change with who asked for the
  # mount -- so these vectors are worth having either way. What the engine
  # route cannot see is anything the app puts on top: the daemon that builds
  # the mount, the options it picks, the identity it mounts under, the ladder
  # it walks. Faults have been found in all four of those in one morning.
  #
  # The bundle needs both halves -- LUKOTTA_BRANDING=beta with
  # LUKOTTA_DEVTOOLS=1 -- or --drive is not compiled in and the app sits in
  # its run loop saying nothing. See dirty-ntfs-repair.sh.
  #
  # OPTS is deliberately not passed. The engine route hands over
  # --ignore-permissions and whatever LUKOTTA_NFS_OPTIONS says; the app decides
  # those for itself, and what it decides is the thing being tested. So a
  # difference here -- vector 7 above all, which is about permissions -- is a
  # real difference between the two routes and not a fault in the run. Read it
  # that way before calling it a regression.
  if [ "${THROUGH_APP:-0}" = "1" ]; then
    local app
    app="$APP_BUNDLE/Contents/MacOS/$(basename "$APP_BUNDLE" .app)"
    if [ "$(strings -a "$app" 2>/dev/null | /usr/bin/grep -c -- "--drive")" -eq 0 ]; then
      echo "error: $APP_BUNDLE has no --drive; it was not built with devtools" >&2
      echo "       LUKOTTA_BRANDING=beta LUKOTTA_DEVTOOLS=1 ./build-app.sh" >&2
      return 1
    fi
    # Give the previous one back first. This is called again for every reopen
    # -- vector 6 is nothing but reopens -- and attaching the same image a
    # second time gives a second device node for one filesystem, which is a way
    # to corrupt a volume rather than a way to test one.
    if [ -n "$DEVICE" ]; then
      # A real drive is not attached and not detached: it is simply there, and
      # the caller named the partition.
      APP_DEV="$DEVICE"
    else
    [ -n "${APP_DEV:-}" ] && hdiutil detach "$APP_DEV" -quiet 2>/dev/null
    APP_DEV="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage \
      "$IMAGE" 2>/dev/null | head -1 | awk '{print $1}')"
    [ -n "${APP_DEV:-}" ] || return 1
    fi

    # The partition, where there is one.
    #
    # `--drive open=` takes /dev/diskNsM, and says so in its own usage line. A
    # fixture with a partition table was handed the whole disk and the app
    # answered "no drive at /dev/diskN" -- recorded as "the engine never mounted
    # it", which reads as a failure to mount rather than as never having been
    # asked. Given the partition, the same image opens exit 0 and serves its
    # three logical volumes.
    #
    # The largest partition, since an EFI system partition is first on a GPT
    # disk and holds nothing worth a vector.
    local biggest
    if [ -n "$DEVICE" ]; then biggest=""; else
    biggest="$(diskutil list "$APP_DEV" 2>/dev/null \
      | awk '$NF ~ /^'"$(basename "$APP_DEV")"'s[0-9]+$/ {
               size = $(NF - 2); unit = $(NF - 1)
               mb = size; if (unit == "GB") mb = size * 1024
               if (mb + 0 > best + 0) { best = mb; node = $NF }
             } END { if (node) print node }')"
    fi
    [ -n "$biggest" ] && APP_DEV="/dev/$biggest"
    # LUKOTTA_PASSPHRASE for an encrypted fixture. Without it the app opens
    # what it can and reports an unencrypted volume for what it cannot, so a
    # LUKS image would fail here for want of a key rather than for anything
    # this harness is trying to find out. The fixtures made by
    # make-test-volumes.sh all use the same one.
    if [ -n "${LUKOTTA_PASSPHRASE:-}" ]; then
      timeout 300 "$app" --drive open="$APP_DEV" \
        passphrase="$LUKOTTA_PASSPHRASE" > "$WORK/app.log" 2>&1 || return 1
    else
      timeout 300 "$app" --drive open="$APP_DEV" > "$WORK/app.log" 2>&1 || return 1
    fi
    # Waited for, not glanced at. The engine route polls for eighty seconds and
    # this checked once: NTFS and LUKS happened to be in the mount table the
    # instant the app returned, exFAT was not, and the run reported "the engine
    # never mounted it" about a mount whose own log said `opened EXFATVEC`.
    for _ in $(seq 1 30); do
      [ -n "$(where)" ] && return 0
      sleep 2
    done
    return 1
  fi
  nohup "$ENGINE" mount -w false "${OPTS[@]}" "$IMAGE" \
    > "$WORK/engine.log" 2>&1 &
  # This image's share, not merely its name anywhere in the table: a stale
  # entry from a previous run carries the same name and answers nothing.
  for _ in $(seq 1 40); do
    [ -n "$(where)" ] && return 0
    sleep 2
  done
  return 1
}


# Whatever the app route attached, given back.
APP_DEV=""
# Unmounted first, then given back.
#
# Detaching the device under a live mount leaves the mount in the table
# pointing at nothing: it answers `mount`, it answers no request, and the next
# run to look for a volume by that name finds it. A stray /Volumes/SWEEP from
# one run was still there while the next was going, which is exactly the shape
# of instrument fault this harness has been fooled by before.
# Puts away everything the drive is serving, deepest first.
#
# `umount -f "$VOL"` takes one share, and a container of logical volumes serves
# three: a parent, and each volume mounted inside it. Taking one left the parent
# holding the device, so the next open failed on a lock still held and every
# vector that reopens a volume failed together -- three open/close cycles
# reported 0 of 3, and each power-loss vector said "never remounted". The same
# image opened and closed by hand manages three cycles in a row, exit 0 and
# three shares each time, which is what said the fault was here.
#
# Deepest first, because unmounting a parent while a volume sits inside it is
# refused for being busy.
unmount_everything() {
  local point
  for point in $(mount | awk '$1 ~ /\.local:/ {
                   for (i = 1; i <= NF; i++) if ($i == "on") print $(i + 1)
                 }' | awk '{ print length, $0 }' | sort -rn | cut -d" " -f2-); do
    umount "$point" >/dev/null 2>&1 || umount -f "$point" >/dev/null 2>&1
  done
}

detach_app_device() {
  [ -n "${APP_DEV:-}" ] || return 0
  # A real drive is let go of, never detached: it is the owner's and it stays
  # plugged in.
  if [ -n "$DEVICE" ]; then unmount_everything; return 0; fi
  # Everything the drive is serving, deepest first.
  #
  # This unmounted one share, found by the device name. A container of logical
  # volumes serves three -- a parent and a volume mounted inside it for each --
  # so unmounting one left the parent holding the device, the next open failed
  # on a lock that was still held, and the vectors that reopen a volume all
  # failed together: three open/close cycles reported 0 of 3, and every
  # power-loss vector said "never remounted". Opened and closed by hand the
  # same image manages three cycles in a row, exit 0, three shares each time.
  #
  # Deepest first, or unmounting the parent is refused for being busy.
  unmount_everything
  hdiutil detach "$APP_DEV" -quiet 2>/dev/null
}
trap detach_app_device EXIT

pass=0; fail=0
note() { if [ "$1" = ok ]; then pass=$((pass+1)); printf '  ok   %s\n' "$2";
         else fail=$((fail+1)); printf '  FAIL %s\n' "$2"; fi }

payload() {  # directory, count, size-bytes
  mkdir -p "$1"
  for i in $(seq 1 "$2"); do head -c "$3" /dev/urandom > "$1/f$i.bin"; done
}

echo "opening $IMAGE"
# The engine's own last words, not a path to them.
#
# This said "see $WORK/engine.log", and $WORK is removed by this script's own
# trap -- and by the next run's sweep if this one is killed. The file was always
# gone by the time anybody looked. Measured on 2026-09-05: luks2-lvm the one
# fixture of seven that failed, and nothing left to say why.
open_image || {
  echo "error: the engine never mounted it. Its last words:" >&2
  sed 's/^/       /' "$WORK/engine.log" 2>/dev/null | tail -12 >&2
  exit 1
}
VOL="$(where)"
[ -n "$VOL" ] || { echo "error: mounted, but nowhere findable" >&2; exit 1; }
echo "mounted at $VOL"

# Whatever a previous run left. A run that stopped partway leaves its filler
# behind, and the next one then starts on a volume with no room and measures
# that instead of the app -- which is exactly what happened on the exFAT
# fixture: it arrived with 4 KB free and every vector was about the space.
for leftover in "$VOL"/vec-*; do [ -e "$leftover" ] && rm -rf "$leftover"; done
free_kb="$(df -k "$VOL" 2>/dev/null | tail -1 | awk '{print $4}')"
printf 'starting with %s MB free\n' "$(( ${free_kb:-0} / 1024 ))"

# These vectors write eighty megabytes, then deliberately fill the volume, and
# the awkward-shapes one alone wants a 512 MB sparse file and a 100 MB solid
# one. On a volume too small for that, they fail on space and read as a fault in
# the app -- which is what a forty-megabyte exFAT fixture produced: a page of
# failures, none of them about the app.
#
# 200 MB, and the awkward-shapes vector sizes itself to what is there.
#
# Raising this to 700 -- what that vector wants at full size -- refused five
# fixtures that had just passed twelve of twelve, because on ext4, XFS and
# btrfs its 512 MB file is a hole and costs nothing. Only exFAT, which has no
# sparse files, writes it out in full, and that is what made a 600 MB exFAT
# fixture fail one vector out of twelve. A fixed figure is wrong in both
# directions: too high refuses volumes that work, too low fails a vector on a
# volume that cannot hold it. So the bar stays where every fixture clears it and
# the vector fits itself to the room.
if [ "${free_kb:-0}" -lt 204800 ]; then
  printf 'error: %s MB free. These vectors need 200 MB and this volume\n' \
    "$(( ${free_kb:-0} / 1024 ))" >&2
  printf '       cannot hold them, so nothing here would be about the app.\n' >&2
  exit 2
fi

# Is this volume actually usable, before anything is measured on it?
#
# A fixture that has been killed mid-write often enough stops answering: `ls`
# and `rm` return "Operation timed out", and an XFS one comes back with "log
# mount failed" in the kernel log. Every vector after that fails, and the page
# of failures reads exactly like corruption in the app. It happened to four
# separate fixtures in one night.
#
# So the volume is asked one cheap question first, and a volume that cannot
# answer it is called what it is.
health_start=$(date +%s)
if ! ls -A "$VOL" >/dev/null 2>&1; then
  echo "error: this volume will not list its own contents. It is a worn-out" >&2
  echo "       fixture, not a fault in the app -- rebuild it and run again." >&2
  exit 2
fi
if [ "$(( $(date +%s) - health_start ))" -gt 5 ]; then
  echo "error: listing this volume took more than five seconds. It is a" >&2
  echo "       worn-out fixture, not a fault in the app -- rebuild it." >&2
  exit 2
fi

SRC="$WORK/src"; payload "$SRC" 40 2000000     # 80 MB, enough to interrupt

# 1. A copy killed partway. What landed before the knife must still be itself.
rm -rf "$VOL/vec-interrupted"; mkdir -p "$VOL/vec-interrupted"
ditto "$SRC" "$VOL/vec-interrupted" & dpid=$!
sleep 4; kill -9 "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null
intact=0; broken=0
for f in "$VOL/vec-interrupted"/*.bin; do
  [ -e "$f" ] || continue
  n="$(basename "$f")"
  # Only files that finished are claimed; a half-written one is expected.
  if [ "$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f")" = "2000000" ]; then
    if cmp -s "$SRC/$n" "$f"; then intact=$((intact+1)); else broken=$((broken+1)); fi
  fi
done
note "$([ "$broken" -eq 0 ] && echo ok || echo no)" \
  "a killed copy leaves no corrupt file behind ($intact whole, $broken wrong)"

# 2. The volume still works afterwards, which is the part that matters.
if printf 'after' > "$VOL/vec-after-kill" 2>/dev/null && [ "$(cat "$VOL/vec-after-kill" 2>/dev/null)" = after ]; then
  note ok "the volume still takes a write after a copy was killed"
else
  note no "the volume still takes a write after a copy was killed"
fi

# 3. Unmounted from underneath a running copy, then opened again.
rm -rf "$VOL/vec-yanked"; mkdir -p "$VOL/vec-yanked"
ditto "$SRC" "$VOL/vec-yanked" >/dev/null 2>&1 & dpid=$!
sleep 3
unmount_everything
kill -9 "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null
if open_image; then
  VOL="$(where)"
  if [ -n "$VOL" ] && [ -d "$VOL" ] && ls "$VOL" >/dev/null 2>&1; then
    note ok "the volume mounts and reads after being unmounted under load"
  else
    note no "the volume mounts and reads after being unmounted under load"
  fi
else
  note no "the volume mounts and reads after being unmounted under load"
fi

# 4. Files written before all that are still exactly themselves.
if [ -n "$VOL" ] && [ -f "$VOL/vec-after-kill" ] && [ "$(cat "$VOL/vec-after-kill" 2>/dev/null)" = after ]; then
  note ok "what was written before the unmount survived it"
else
  note no "what was written before the unmount survived it"
fi

# 5. Run it out of space. ENOSPC is an answer; a hang is not.
# Everything the vectors have written, not only what filled it.
#
# Removing vec-full alone left every earlier vector's data in place, and on a
# small volume that is most of it: a 376 MB logical volume came back with 28 KB
# free and this was reported as the room not coming back. By hand, on a clean
# volume of the same kind, filling to zero and deleting returns 242 MB at once
# -- so the space is reclaimed properly and what was measured was the harness's
# own leftovers.
#
# Nothing after this point reads what came before it: each vector checks its own
# data before the next begins.
rm -rf "$VOL"/vec-*; mkdir -p "$VOL/vec-full"
# Long enough to actually fill what is there.
#
# 300 seconds is plenty for a two-gigabyte fixture and nothing like enough for a
# real drive: the owner's stick had 20 GB free and the fill was still going when
# the bound cut it, reported as "a full volume answers rather than hanging" --
# which is the harness giving up, dressed as the app hanging.
#
# Four megabytes a second, measured rather than guessed.
#
# Ten was the first guess and it was still too tight: the owner's drive had
# 20 GB free and the fill was cut at 2015 seconds without finishing, so the real
# rate through this stack is under 10 MB/s. Four gives room for a slow stick and
# still finishes.
#
# It makes this the long vector on a large drive -- 20 GB free is over an hour
# -- and that is what filling a real volume costs. The alternative is not
# testing what a full volume does, and a full volume is where a copy goes wrong
# in the most ordinary way there is.
fill_free_mb=$(df -m "$VOL" 2>/dev/null | tail -1 | awk '{print $4}')
fill_bound=$(( ${fill_free_mb:-0} / 4 ))
[ "$fill_bound" -lt 300 ] && fill_bound=300
start=$(date +%s)
timeout "$fill_bound" dd if=/dev/zero of="$VOL/vec-full/filler.bin" bs=1048576 status=none 2>"$WORK/full.err"
rc=$?; elapsed=$(( $(date +%s) - start ))
if [ "$rc" = 124 ]; then
  note no "a full volume answers rather than hanging (still going after ${elapsed}s of ${fill_bound}s)"
elif grep -qiE 'no space|full' "$WORK/full.err" 2>/dev/null || [ "$rc" != 0 ]; then
  note ok "a full volume answers with an error, in ${elapsed}s"
else
  note no "a full volume answers with an error (dd claimed success)"
fi
# The whole directory, and then a look at whether the room actually came back.
#
# Removing the file alone left the directory, and on a small volume the space
# was not reclaimed by the time the next vector ran. Every vector after this one
# then failed with ENOSPC and was reported as a fault in the app: permissions
# unreadable, concurrent writers all differing, every fsynced file lost. None of
# that happened. The volume was full, because this filled it.
rm -rf "$VOL/vec-full"
for _ in $(seq 1 15); do
  free_kb="$(df -k "$VOL" 2>/dev/null | tail -1 | awk '{print $4}')"
  [ "${free_kb:-0}" -gt 20480 ] && break
  sleep 2
done
if [ "${free_kb:-0}" -le 20480 ]; then
  note no "the room comes back after a full volume (${free_kb:-0} KB free)"
  printf '\nstopping here: the volume is still full, so every vector after this\n'
  printf 'one would fail on space and be read as a fault in the app.\n'
  printf '%s passed, %s failed\n' "$pass" "$fail"
  exit 1
fi

# 6. Opened and closed repeatedly, which is what a person does over a week.
# The machine keeps the image after the share goes. Mounter.mount says so:
# "An eject returns as soon as the volume leaves the mount table; the machine
# that served it keeps the image file for another half-minute, and opening the
# same file inside that window meets a locked file or a read-only mount nothing
# announced." The app waits for that; anything else driving the engine must too,
# and a harness that does not reports a failure to reopen that is its own
# impatience.
cycles=0
for _ in 1 2 3; do
  unmount_everything
  for _ in $(seq 1 30); do
    pgrep -f "anylinuxfs mount.*$(basename "$IMAGE")" >/dev/null 2>&1 || break
    sleep 2
  done
  if open_image; then VOL="$(where)"; [ -n "$VOL" ] && ls "$VOL" >/dev/null 2>&1 && cycles=$((cycles+1)); fi
done
note "$([ "$cycles" -eq 3 ] && echo ok || echo no)" "three open/close cycles in a row ($cycles of 3)"

# 7. Permissions. The export squashes who is asking and --ignore-permissions
#    makes everything appear as the person who opened the drive, which is the
#    point -- an NTFS volume has no idea what a uid is. What matters is that a
#    file written as read-only is still readable, that a directory can be
#    entered, and that nothing arrives inaccessible to the person who put it
#    there.
rm -rf "$VOL/vec-perms"; mkdir -p "$VOL/vec-perms"
printf 'readonly' > "$VOL/vec-perms/ro.txt" 2>/dev/null
chmod 444 "$VOL/vec-perms/ro.txt" 2>/dev/null
printf 'executable' > "$VOL/vec-perms/exe.sh" 2>/dev/null
chmod 755 "$VOL/vec-perms/exe.sh" 2>/dev/null
mkdir -p "$VOL/vec-perms/dir" 2>/dev/null
printf 'inside' > "$VOL/vec-perms/dir/f.txt" 2>/dev/null
readable=0
[ "$(cat "$VOL/vec-perms/ro.txt" 2>/dev/null)" = readonly ] && readable=$((readable + 1))
[ "$(cat "$VOL/vec-perms/exe.sh" 2>/dev/null)" = executable ] && readable=$((readable + 1))
[ "$(cat "$VOL/vec-perms/dir/f.txt" 2>/dev/null)" = inside ] && readable=$((readable + 1))
note "$([ "$readable" -eq 3 ] && echo ok || echo no)" \
  "everything written is readable by whoever wrote it ($readable of 3)"

# 7b. The awkward names and shapes item 9 asks for by name: scripts other than
#     Latin, an emoji, quotes and spaces, a filename at the length limit, a deep
#     path, a file that is almost entirely hole, and one large enough that it
#     cannot be held in memory on the way through.
#
#     These are checked together because they fail together: a name mangled on
#     the way out and a name mangled on the way back look identical unless the
#     bytes are compared, and a sparse file that arrives fully allocated is only
#     visible beside one that does not.
awkward="$WORK/awkward"
rm -rf "$awkward"; mkdir -p "$awkward/a/b/c/d/e/f/g/h/i/j"
head -c 4096 /dev/urandom > "$awkward/日本語のファイル名.bin"
head -c 4096 /dev/urandom > "$awkward/Ελληνικά-αρχείο.bin"
head -c 4096 /dev/urandom > "$awkward/Ärger-Öl-Übung-ß.bin"
head -c 4096 /dev/urandom > "$awkward/файл-кириллица.bin"
head -c 4096 /dev/urandom > "$awkward/📁-emoji-🎉.bin"
# A name carrying an apostrophe, built with printf so the quoting stays
# readable rather than becoming a puzzle.
quoted="$(printf "name with spaces and %s quotes %s.bin" "'" "'")"
head -c 4096 /dev/urandom > "$awkward/$quoted"
head -c 4096 /dev/urandom > "$awkward/a/b/c/d/e/f/g/h/i/j/deep.bin"
longname="$(/usr/bin/python3 -c 'print("n" * 250)')"
head -c 4096 /dev/urandom > "$awkward/$longname.bin" 2>/dev/null || true
# The hole and the large file, sized to the volume rather than to a constant.
#
# 512 MB and 100 MB are what these want. On ext4, XFS and btrfs the hole costs
# nothing and both fit anywhere; on exFAT there are no sparse files, so the hole
# is written out in full and 620 MB is wanted. Fixed sizes therefore fail the
# vector on any small exFAT volume while passing everywhere else, which reads as
# a narrow defect in the app rather than as a volume with no room in it.
#
# Half the free space for the hole, a fifth for the large file, capped at what
# was asked for. A volume that can take the full sizes gets exactly the test it
# had before.
awkward_free_mb=$(df -m "$VOL" 2>/dev/null | tail -1 | awk '{print $4}')
hole_mb=$(( ${awkward_free_mb:-200} / 2 )); [ "$hole_mb" -gt 512 ] && hole_mb=512
big_mb=$(( ${awkward_free_mb:-200} / 5 )); [ "$big_mb" -gt 100 ] && big_mb=100
[ "$hole_mb" -lt 1 ] && hole_mb=1
[ "$big_mb" -lt 1 ] && big_mb=1
hole_bytes=$(( hole_mb * 1048576 ))
dd if=/dev/zero of="$awkward/sparse.bin" bs=1 count=0 seek="$hole_bytes" 2>/dev/null
printf 'end' | dd of="$awkward/sparse.bin" bs=1 seek=$(( hole_bytes - 12 )) \
  conv=notrunc 2>/dev/null
head -c $(( big_mb * 1048576 )) /dev/urandom > "$awkward/large-${big_mb}MB.bin"

rm -rf "$VOL/vec-awkward"
if cp -R "$awkward" "$VOL/vec-awkward" 2>/dev/null; then
  same=0; differs=0; missing=0
  while IFS= read -r -d "" f; do
    rel="${f#"$awkward"/}"
    if [ ! -f "$VOL/vec-awkward/$rel" ]; then missing=$((missing + 1))
    elif cmp -s "$f" "$VOL/vec-awkward/$rel"; then same=$((same + 1))
    else differs=$((differs + 1)); fi
  done < <(find "$awkward" -type f -print0)
  note "$([ "$differs" -eq 0 ] && [ "$missing" -eq 0 ] && echo ok || echo no)" \
    "awkward names and shapes survive a copy ($same whole, $differs wrong, $missing missing)"
else
  note no "awkward names and shapes survive a copy (the copy would not run)"
fi
rm -rf "$VOL/vec-awkward"

# 8. Two writers and a reader at once. A copy is not the only thing touching a
#    drive -- Spotlight indexes it, Finder stats it, somebody opens a file from
#    it -- and the interesting question is whether concurrent work corrupts
#    anything rather than whether it is fast.
rm -rf "$VOL/vec-conc"; mkdir -p "$VOL/vec-conc/a" "$VOL/vec-conc/b"
payload "$WORK/conc" 12 300000
ditto "$WORK/conc" "$VOL/vec-conc/a" >/dev/null 2>&1 &
w1=$!
ditto "$WORK/conc" "$VOL/vec-conc/b" >/dev/null 2>&1 &
w2=$!
( for _ in $(seq 1 40); do cat "$VOL"/vec-perms/* >/dev/null 2>&1; sleep 0.25; done ) &
r1=$!
wait "$w1" 2>/dev/null; wait "$w2" 2>/dev/null; kill "$r1" 2>/dev/null
cbad=0; cn=0
for side in a b; do
  while IFS= read -r f; do
    rel="${f#"$WORK/conc"/}"; cn=$((cn + 1))
    cmp -s "$f" "$VOL/vec-conc/$side/$rel" || cbad=$((cbad + 1))
  done < <(find "$WORK/conc" -type f)
done
note "$([ "$cbad" -eq 0 ] && echo ok || echo no)" \
  "two writers and a reader at once leave nothing wrong ($cn compared, $cbad differing)"

# 9. Power loss mid-write.
#
#    Every other case here kills the copier. This one kills the machine, and
#    those are different accidents. With ditto killed the guest is alive and
#    flushes what it holds; with the machine killed the guest dies with a page
#    cache full of writes that never reached the image. Nothing is unmounted
#    first -- an unmount would flush, which is the courtesy a power cut does
#    not extend.
#
#    WHAT THIS CLAIMS, AND WHY IT IS NOT WHAT IT CLAIMED FIRST
#
#    The first version asserted that a file present at its full length must
#    have the right bytes: torn length is honest, torn content is not. Run
#    against XFS it failed 30 of 30 -- every file full length, every one wrong
#    -- which looked like serious corruption.
#
#    It was not. The files hold real data in the middle and zeros at both ends;
#    one measured 947137 non-zero bytes out of 1000000, and not one of the 30
#    was entirely zero. That is the NFS client flushing cached writes out of
#    order: a write landing at a high offset extends the file to full length
#    and leaves the earlier range unwritten, so when the guest dies the gaps
#    stay zero. The premise that bytes arrive in order is what was wrong, and
#    over NFS it was never true.
#
#    So the claim is the one that means something to a person: data the writer
#    was told had been committed is still there afterwards. Files are written
#    and fsynced one at a time, and only those are held to byte-for-byte
#    identity. Whatever was still in flight may be anything at all, including a
#    full-length file that is quietly full of holes -- which is worth knowing
#    on its own, because after a crash "it is there and it is the right size"
#    is not evidence that a file is complete.
rm -rf "$VOL/vec-power"; mkdir -p "$VOL/vec-power"

# 13. A copy over files that are already there.
#
#    The most ordinary thing anybody does with a drive, and no vector above did
#    it: every one of them copies into a name that is free. On 2026-09-05 that
#    gap hid a fault for a whole evening. A directory an interrupted copy had
#    damaged took a copy over existing files, reported success, kept the older
#    files and left the newer bytes stranded under the copier's temporary names
#    -- `mv` returns 1 inside the guest, and over NFS the host is told it
#    worked, so ditto exits 0. Sixty files, every one of them the old one.
#
#    Both halves are checked, because either alone would have missed it: the
#    content must be the second tree, and nothing of the copier's may be left
#    lying about. The two trees have the same names and different sizes, so a
#    file that was not replaced is unambiguous rather than merely different.
payload "$WORK/ow-first" 20 100000
payload "$WORK/ow-second" 20 150000
rm -rf "$VOL/vec-overwrite"
ditto "$WORK/ow-first" "$VOL/vec-overwrite" >/dev/null 2>&1
ditto "$WORK/ow-second" "$VOL/vec-overwrite" > "$WORK/ow.err" 2>&1
want="$( (cd "$WORK/ow-second" && find . -type f -exec shasum -a 256 {} \; | sort) \
  | shasum -a 256 | awk '{print $1}')"
got="$( (cd "$VOL/vec-overwrite" && find . -type f ! -name '.*' -exec shasum -a 256 {} \; \
  | sort) | shasum -a 256 | awk '{print $1}')"
strays="$(find "$VOL/vec-overwrite" -maxdepth 1 \( -name '.BC.T_*' -o -name '.nfs*' \) \
  2>/dev/null | wc -l | tr -d ' ')"
if [ "$want" = "$got" ] && [ "${strays:-0}" -eq 0 ]; then
  note ok "a copy over files already there replaced every one of them"
elif [ "$want" != "$got" ]; then
  note bad "a copy over files already there left older ones in place"
else
  note bad "the copy replaced them and left $strays temporary file(s) behind"
fi
rm -rf "$VOL/vec-overwrite"
payload "$WORK/power" 30 1000000

# Committed: written and fsynced before anything is killed. dd's conv=fsync
# returns only once the client has had its COMMIT answered, so each of these
# is data the writer was told is on the disk.
committed=0
for i in 1 2 3 4 5 6 7 8; do
  if dd if="$WORK/power/f$i.bin" of="$VOL/vec-power/committed-$i.bin" \
        bs=1000000 conv=fsync status=none 2>/dev/null; then
    committed=$((committed + 1))
  fi
done

# In flight: a bulk copy nobody has confirmed anything about.
ditto "$WORK/power" "$VOL/vec-power/inflight" >/dev/null 2>&1 &
ppid=$!
sleep 5
kill -9 "$ppid" 2>/dev/null; wait "$ppid" 2>/dev/null

# The machine, not the mount. -9 so nothing gets the chance to be tidy.
pkill -9 -f "anylinuxfs mount.*$IMAGE" >/dev/null 2>&1
pkill -9 -f "krun.*$(basename "$IMAGE")" >/dev/null 2>&1
sleep 3
unmount_everything
for _ in $(seq 1 30); do
  pgrep -f "anylinuxfs mount.*$(basename "$IMAGE")" >/dev/null 2>&1 || break
  sleep 2
done

if open_image; then VOL="$(where)"; else VOL=""; fi
if [ -n "$VOL" ] && ls "$VOL" >/dev/null 2>&1; then
  note ok "the filesystem comes back after the machine was killed mid-write"
  cn=0; cbad=0; cgone=0
  for i in 1 2 3 4 5 6 7 8; do
    dst="$VOL/vec-power/committed-$i.bin"
    [ -e "$dst" ] || { cgone=$((cgone + 1)); continue; }
    cn=$((cn + 1))
    cmp -s "$WORK/power/f$i.bin" "$dst" || cbad=$((cbad + 1))
  done
  note "$([ "$cbad" -eq 0 ] && [ "$cgone" -eq 0 ] && echo ok || echo no)" \
    "every fsynced file survived power loss ($cn of $committed present, $cbad wrong, $cgone lost)"

  # Not a pass or a fail, but the number worth having: how much of what was in
  # flight came back looking complete while holding holes.
  looks_whole=0; really_whole=0
  if [ -d "$VOL/vec-power/inflight" ]; then
    for f in "$VOL"/vec-power/inflight/*.bin; do
      [ -e "$f" ] || continue
      sz="$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f")"
      [ "$sz" = 1000000 ] || continue
      looks_whole=$((looks_whole + 1))
      cmp -s "$WORK/power/$(basename "$f")" "$f" && really_whole=$((really_whole + 1))
    done
  fi
  printf '  note %s of %s in-flight files came back at full length; %s of those were actually complete\n' \
    "$looks_whole" 30 "$really_whole"

  if printf 'after' > "$VOL/vec-power-after" 2>/dev/null \
     && [ "$(cat "$VOL/vec-power-after" 2>/dev/null)" = after ]; then
    note ok "the volume takes a write again after power loss"
  else
    note no "the volume takes a write again after power loss"
  fi
else
  note no "the filesystem comes back after the machine was killed mid-write"
  note no "every fsynced file survived power loss (never remounted)"
  note no "the volume takes a write again after power loss (never remounted)"
fi

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
