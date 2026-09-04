#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# The unpacked Linux environment is the one this app carries.
#
# WHAT IT GUARDS
#
# The environment is unpacked into the user's home on first use and kept between
# updates. Replacing it when the app changes is guarded by a version comparison
# that had never once been true: the file it read, rootfs.ver, is upstream's
# image release, and nothing this project does to the guest -- the trim, the
# vendored tools, the NTFS checker -- moves it. So a release whose whole point
# was a new guest tool compared 1.5.1 against 1.5.1, decided nothing had
# changed, and reached nobody who already had the app. They kept the environment
# from the day they installed and ran the new engine against it.
#
# That is not only a tool that never arrives. A guest which does not match the
# bundle makes the engine replace its vmproxy on every mount, and that path
# takes the engine's global lock exclusively -- so the second drive a person
# opens is refused while the first is open. See two-at-once.sh.
#
# rootfs.build is this project's own number, a digest of what was packed. It is
# separate from rootfs.ver on purpose: the engine compiles its copy of that file
# in as a constant and compares against it, so a value it does not recognise
# makes it re-initialise the image every time.
#
#   ./scripts/guest-matches-the-bundle.sh
set -uo pipefail

ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Beta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
[ -d "$APP_BUNDLE" ] || { echo "error: no app at $APP_BUNDLE" >&2; exit 2; }
APP_ID="$(/usr/bin/defaults read "$APP_BUNDLE/Contents/Info.plist" CFBundleIdentifier 2>/dev/null)"
[ -n "$APP_ID" ] || { echo "error: no bundle identifier for $APP_BUNDLE" >&2; exit 2; }

SHIPPED="$APP_BUNDLE/Contents/Resources/engine/alpine"
HOME_DIR="$HOME/Library/Application Support/$APP_ID/engine/.anylinuxfs/alpine"

[ -f "$SHIPPED/rootfs.build" ] || {
  echo "error: the bundle carries no rootfs.build; re-run scripts/vendor-engine.sh" >&2
  exit 1; }
[ -d "$HOME_DIR/rootfs" ] || {
  echo "error: $APP_ID has not unpacked its guest yet; open a drive with it once" >&2
  exit 2; }

shipped="$(tr -d '[:space:]' < "$SHIPPED/rootfs.build")"
unpacked="$(tr -d '[:space:]' < "$HOME_DIR/rootfs.build" 2>/dev/null || true)"

echo "  bundle carries   ${shipped:-nothing}"
echo "  home has         ${unpacked:-nothing}"

# The tools this project puts into the guest, which upstream's image has none
# of: their absence is what the version comparison is really guarding against.
# -e OR -L, because half of these are symlinks to absolute paths inside the
# guest -- sbin/mount.ntfs points at /bin/ntfs-3g -- and an absolute link into a
# root that is not this Mac's dangles when it is followed from here. Testing
# with -e alone reported the tool missing from a guest that has it, which is the
# check answering a question about the host while claiming to answer one about
# the guest.
missing=""
for tool in usr/sbin/ntfsck sbin/mount.ntfs sbin/mount.ntfs-3g; do
  [ -e "$HOME_DIR/rootfs/$tool" ] || [ -L "$HOME_DIR/rootfs/$tool" ] \
    || missing="$missing $tool"
done

echo
if [ -n "$missing" ]; then
  echo "RESULT: the unpacked guest is missing$missing" >&2
  exit 1
fi
if [ "$shipped" != "$unpacked" ]; then
  echo "RESULT: the unpacked guest is not the one this app carries" >&2
  echo "        (${unpacked:-nothing} against $shipped)" >&2
  exit 1
fi
echo "RESULT: the unpacked guest is the one this app carries, tools and all"
