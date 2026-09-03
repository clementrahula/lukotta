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
# Which bundle, taken from the engine like every other harness here.
#
# This named the dev bundle and nothing else, so on a Mac without one it
# reported "this build has no harness" -- which reads as a broken build rather
# than as a missing app, and was recorded as a failing claim twice on a machine
# where nothing was wrong.
LUKOTTA_ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Dev.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_BUNDLE="${LUKOTTA_ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP="$APP_BUNDLE/Contents/MacOS/$(basename "$APP_BUNDLE" .app)"
GUEST="$HOME/Library/Application Support/com.lukotta.dev/engine/.anylinuxfs/alpine"
CACHE="${LUKOTTA_E2E_CACHE:-$HOME/Library/Caches/dev.lukotta.e2e}"
PASSPHRASE="lukotta-e2e"

[ -x "$APP" ] || {
  echo "no dev build; run LUKOTTA_DEVTOOLS=1 LUKOTTA_BRANDING=dev ./build-app.sh"
  exit 2
}
[ -f "$CACHE/container.img" ] || { echo "no fixtures; run ./scripts/e2e.sh once"; exit 2; }

# The harness has to be in the build, or the argument is ignored and the app
# simply launches: no output, no drive, and nothing to read a verdict from.
#
# Asked by running it. Looking for the string in the binary does not work --
# "--drive" is seven bytes, and Swift keeps a string that short inside the
# instruction rather than in a section any tool can read out -- so the guard
# meant to catch a build without the harness reported every build as one.
probe="$(timeout 20 "$APP" --drive 2>&1)"
if ! printf '%s' "$probe" | grep -q "usage: --drive"; then
  echo "this build has no harness; rebuild with LUKOTTA_DEVTOOLS=1"
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

export ANYLINUXFS_HOME="$HOME/Library/Application Support/com.lukotta.dev/engine"
out="$(mktemp)"
LUKOTTA_E2E_QUICK=1 "$APP" --e2e \
  container="$CACHE/container.img" passphrase="$PASSPHRASE" \
  plain="$CACHE/plain.img" ntfs="$CACHE/plain.ntfs.img" >"$out" 2>&1
status=$?

ok="$(grep -c '^  ok' "$out" || true)"
broke="$(grep -c '^  FAIL' "$out" || true)"
echo "--- what the app said ---"
tail -8 "$out"
echo "--- $ok ok, $broke failed, exit $status ---"

# Three things, not one, for the same reason preflight.sh checks three: a
# harness that dies at launch leaves an empty log, and counting only failures
# reads that as a clean run.
[ "$status" -eq 0 ] || { echo "FAIL: the harness exited $status"; exit 1; }
[ "$ok" -gt 0 ] || { echo "FAIL: nothing was checked, so nothing was tested"; exit 1; }
[ "$broke" -eq 0 ] || { echo "FAIL: $broke checks failed on a first run"; exit 1; }
echo "PASS: the drive opened on a first run, and the app said so"
