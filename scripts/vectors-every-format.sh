#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Item 9's vectors, on every format the app claims, through the app.
#
# integrity-vectors.sh takes one image. Item 9 asks for every vector and item 6
# asks for every format, so the two together are the vectors run once per
# fixture -- and running them by hand means four commands, four chances to pass
# the wrong bundle or forget the passphrase, and a gap of twenty minutes
# between each in which the next one is not started.
#
# THROUGH_APP=1 throughout, because the engine route cannot see what the app
# puts on top of it: the daemon that builds the mount, the options it picks,
# the identity it mounts under, the ladder it walks. Four faults were found in
# exactly those four places on 2026-09-03, so the route matters.
#
#   ./scripts/vectors-every-format.sh
#   FIXTURES="ntfs-vectors ext4-vectors" ./scripts/vectors-every-format.sh
#
# The bundle must carry --drive and have a daemon; see dirty-ntfs-repair.sh.
# Build one with LUKOTTA_BRANDING=beta LUKOTTA_DEVTOOLS=1 ./build-app.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${LUKOTTA_TESTVOLS:-$HOME/.lukotta-testvols}"
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Beta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"

# Every format the app advertises that has a fixture, and the encrypted ones
# with the key the fixtures are made with. A fixture that is not there is named
# and skipped rather than silently missed: "12 passed" over three formats when
# five were meant is the kind of result that reads as success.
FIXTURES="${FIXTURES:-ntfs-vectors ext4-vectors btrfs-vectors exfat-vectors luks-ext4 luks-xfs}"
PASSPHRASE="${LUKOTTA_PASSPHRASE:-lukotta-test-pass}"

ran=0; failed=0; missing=""
for name in $FIXTURES; do
  image="$OUT/$name.img"
  if [ ! -f "$image" ]; then
    missing="$missing $name"
    continue
  fi
  printf '\n===== %s =====\n' "$name"
  # Given back between runs. A volume left mounted from the last format is a
  # volume the next run can find instead of its own, and this harness has been
  # fooled by exactly that before.
  mount | /usr/bin/grep ':/mnt/' | awk '{print $3}' | while read -r point; do
    umount "$point" >/dev/null 2>&1 || umount -f "$point" >/dev/null 2>&1
  done
  /usr/bin/pkill -f "anylinuxfs mount" >/dev/null 2>&1
  sleep 3
  hdiutil info 2>/dev/null | /usr/bin/grep '^/dev/disk' | awk '{print $1}' \
    | while read -r dev; do hdiutil detach "$dev" -quiet >/dev/null 2>&1; done
  sleep 2

  THROUGH_APP=1 LUKOTTA_PASSPHRASE="$PASSPHRASE" \
    bash "$HERE/scripts/integrity-vectors.sh" "$image" "$ENGINE"
  status=$?
  ran=$((ran + 1))
  [ "$status" -eq 0 ] || failed=$((failed + 1))
done

printf '\n===== every format =====\n'
printf '%s formats run, %s with failures\n' "$ran" "$failed"
[ -n "$missing" ] && printf 'no fixture for:%s\n' "$missing" >&2
[ "$failed" -eq 0 ] && [ -z "$missing" ]
