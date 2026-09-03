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
ENGINE="${2:-/Applications/Lukotta Dev.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
[ -f "$IMAGE" ] || { echo "usage: $0 <image> [engine]" >&2; exit 2; }
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
ORIGINAL="$IMAGE"
# The copy is named after this run's workspace, not after the original.
#
# The engine names its share from the image's file name, and `where` finds a
# mount by that name. Two runs of the same fixture therefore produce two shares
# called the same thing, and a mount left behind by a killed engine is matched
# by the next run -- which then measures the previous run's volume, full and
# already spoiled. That is what "52 MB free" was.
IMAGE="$WORK/$(basename "$ORIGINAL" .img)-$(basename "$WORK").img"
printf 'copying the fixture so this run cannot spoil the next one\n'
cp "$ORIGINAL" "$IMAGE" || { echo "error: could not copy $ORIGINAL" >&2; exit 2; }
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
  mount | awk -v want="$(basename "$IMAGE" .img)-img.local:" \
    '$1 ~ want {for(i=1;i<=NF;i++) if($i=="on") {print $(i+1); exit}}'
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


pass=0; fail=0
note() { if [ "$1" = ok ]; then pass=$((pass+1)); printf '  ok   %s\n' "$2";
         else fail=$((fail+1)); printf '  FAIL %s\n' "$2"; fi }

payload() {  # directory, count, size-bytes
  mkdir -p "$1"
  for i in $(seq 1 "$2"); do head -c "$3" /dev/urandom > "$1/f$i.bin"; done
}

echo "opening $IMAGE"
open_image || { echo "error: the engine never mounted it; see $WORK/engine.log" >&2; exit 1; }
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

# These vectors write eighty megabytes and then deliberately fill the volume.
# On a volume too small for that, every one of them fails on space and reads as
# a fault in the app -- which is what a forty-megabyte exFAT fixture produced:
# a page of failures, none of them about the app.
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
umount -f "$VOL" >/dev/null 2>&1
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
rm -rf "$VOL/vec-full"; mkdir -p "$VOL/vec-full"
start=$(date +%s)
timeout 300 dd if=/dev/zero of="$VOL/vec-full/filler.bin" bs=1048576 status=none 2>"$WORK/full.err"
rc=$?; elapsed=$(( $(date +%s) - start ))
if [ "$rc" = 124 ]; then
  note no "a full volume answers rather than hanging (still going after ${elapsed}s)"
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
  umount -f "$VOL" >/dev/null 2>&1
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
dd if=/dev/zero of="$awkward/sparse.bin" bs=1 count=0 seek=536870912 2>/dev/null
printf 'end' | dd of="$awkward/sparse.bin" bs=1 seek=536870900 conv=notrunc 2>/dev/null
head -c 104857600 /dev/urandom > "$awkward/large-100MB.bin"

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
umount -f "$VOL" >/dev/null 2>&1
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
