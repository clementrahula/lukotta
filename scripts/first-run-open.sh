#!/bin/bash
# Does a drive open on a Mac that has never run this app?
#
# The Linux environment is unpacked by the first mount that needs it. That
# attempt then ends having unpacked rather than mounted, and what somebody saw
# was "The drive was not opened", with the last line of the unpacking offered
# as the reason: removed '/etc/exports'. A first run, on a new install and
# again after an update replaces the environment.
#
# So the environment is taken away and a drive is opened. Nothing about this
# test is about which drive: any image will do, and an unencrypted one is used
# so no passphrase is involved in a question that has nothing to do with one.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Lukotta Dev.app/Contents/MacOS/Lukotta Dev"
GUEST="$HOME/Library/Application Support/com.lukotta.dev/engine/.anylinuxfs/alpine"
IMAGE="${1:-$HOME/.lukotta-testvols/ext4run.img}"

[ -x "$APP" ] || { echo "no dev build; run ./build-app.sh"; exit 2; }
[ -f "$IMAGE" ] || { echo "no image at $IMAGE"; exit 2; }

aside="$GUEST.aside.$$"
restore() {
  if [ -d "$aside" ]; then rm -rf "$GUEST" 2>/dev/null; mv "$aside" "$GUEST"; fi
}
trap restore EXIT

if [ -d "$GUEST" ]; then
  mv "$GUEST" "$aside" || { echo "could not move the environment aside"; exit 2; }
fi
echo "the Linux environment is absent: $([ -d "$GUEST" ] && echo no || echo yes)"

out="$(mktemp)"
"$APP" --drive "open=$IMAGE" >"$out" 2>&1
status=$?

echo "--- what the app said ---"
tail -6 "$out"
echo "---"

if grep -qi "not opened\|could not be opened\|removed '/etc" "$out"; then
  echo "FAIL: the first run reported a drive that would not open"
  exit 1
fi
if [ $status -ne 0 ]; then
  echo "FAIL: exit $status"
  exit 1
fi
echo "PASS: the drive opened on a first run"
