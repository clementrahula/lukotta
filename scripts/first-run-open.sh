#!/bin/bash
# Does a drive open on a Mac that has never run this app?
#
# The Linux environment is unpacked by the first mount that needs it. That
# attempt then ends having unpacked rather than mounted, and what somebody saw
# was "The drive was not opened", with the last line of the unpacking offered
# as the reason: removed '/etc/exports'. A first run, on a new install, and
# again after an update replaces the environment.
#
# So the environment is taken away and a drive is opened. Nothing here is about
# which drive: any image will do, and an unencrypted one is used so that no
# passphrase is involved in a question that has nothing to do with one.
#
# The app must SAY it opened the drive. An earlier version of this script
# looked for the failure and passed when it did not find it, which is a pass
# every silent build earns -- including the one this was first run against,
# which had no --drive at all and printed nothing.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Lukotta Dev.app/Contents/MacOS/Lukotta Dev"
GUEST="$HOME/Library/Application Support/com.lukotta.dev/engine/.anylinuxfs/alpine"
IMAGE="${1:-$HOME/.lukotta-testvols/ext4run.img}"

[ -x "$APP" ] || {
  echo "no dev build; run LUKOTTA_DEVTOOLS=1 LUKOTTA_BRANDING=dev ./build-app.sh"
  exit 2
}
[ -f "$IMAGE" ] || { echo "no image at $IMAGE"; exit 2; }

# The harness has to be in the build, or --drive is ignored and the app simply
# launches: no output, no drive, and nothing to read a verdict from.
if ! strings "$APP" 2>/dev/null | grep -q -- "--drive"; then
  echo "this build has no --drive; rebuild with LUKOTTA_DEVTOOLS=1"
  exit 2
fi

aside="$GUEST.aside.$$"
restore() {
  if [ -d "$aside" ]; then rm -rf "$GUEST" 2>/dev/null; mv "$aside" "$GUEST"; fi
}
trap restore EXIT

if [ -d "$GUEST" ]; then
  mv "$GUEST" "$aside" || { echo "could not move the environment aside"; exit 2; }
fi
[ -d "$GUEST" ] && { echo "the environment is still there; nothing was tested"; exit 2; }
echo "the Linux environment was taken away"

out="$(mktemp)"
"$APP" --drive "open=$IMAGE" >"$out" 2>&1
status=$?

echo "--- what the app said ---"
cat "$out"
echo "---"

if [ ! -s "$out" ]; then
  echo "FAIL: the app said nothing, so nothing was tested"
  exit 1
fi
if ! grep -q "^opened " "$out"; then
  echo "FAIL: the app did not say it opened the drive"
  exit 1
fi
if grep -qi "not opened\|could not be opened\|removed '/etc" "$out"; then
  echo "FAIL: the first run reported a drive that would not open"
  exit 1
fi
[ $status -eq 0 ] || { echo "FAIL: exit $status"; exit 1; }
echo "PASS: the drive opened on a first run, and the app said so"
