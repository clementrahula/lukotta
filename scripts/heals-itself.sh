#!/bin/bash
# Does the app put itself back together after somebody deletes what it needs?
#
# Three ways it can be broken, each worse than the last:
#   gone       the Linux environment removed outright
#   half       the environment there but the root filesystem taken out of it
#   shredded   the root filesystem there but emptied of what it holds
#
# None of these should be anybody's problem. The app unpacks what it needs and
# opens the drive, with nothing said and nothing to click. What it used to do
# was spend the attempt unpacking and then report that the drive would not open.
#
# Nothing here exports ANYLINUXFS_HOME: the app has to find its own directory,
# which is the fault that hid behind every harness that set it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP="${LUKOTTA_APP:-/Applications/Lukotta Dev.app}"
NAME="$(basename "$APP" .app)"
BIN="$APP/Contents/MacOS/$NAME"
CACHE="${LUKOTTA_E2E_CACHE:-$HOME/Library/Caches/dev.lukotta.e2e}"
IDENT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null)"
GUEST="$HOME/Library/Application Support/$IDENT/engine/.anylinuxfs/alpine"

[ -x "$BIN" ] || { echo "no build at $APP"; exit 2; }
[ -f "$CACHE/container.img" ] || { echo "no fixtures; run ./scripts/e2e.sh once"; exit 2; }
probe="$(timeout 20 "$BIN" --drive 2>&1)"
printf '%s' "$probe" | grep -q "usage: --drive" || {
  echo "this build has no harness; rebuild with LUKOTTA_DEVTOOLS=1"; exit 2; }

break_it() {
  case "$1" in
    gone)     rm -rf "$GUEST" ;;
    half)     rm -rf "$GUEST/rootfs" ;;
    shredded) rm -rf "$GUEST/rootfs"; mkdir -p "$GUEST/rootfs" ;;
  esac
}

fail=0
for how in gone half shredded; do
  break_it "$how"
  out="$(mktemp)"
  env -u ANYLINUXFS_HOME LUKOTTA_E2E_QUICK=1 "$BIN" --e2e \
    container="$CACHE/container.img" passphrase="lukotta-e2e" \
    plain="$CACHE/plain.img" >"$out" 2>&1
  status=$?
  ok="$(grep -c '^  ok' "$out" || true)"
  broke="$(grep -c '^  FAIL' "$out" || true)"

  if [ "$status" -ne 0 ] || [ "$ok" -eq 0 ] || [ "$broke" -ne 0 ]; then
    echo "FAIL: $NAME did not heal from '$how' ($ok ok, $broke failed, exit $status)"
    tail -4 "$out" | sed 's/^/       /'
    fail=1
  else
    echo "ok   $NAME healed from '$how' ($ok checks)"
  fi
  [ -d "$HOME/.anylinuxfs" ] && { echo "FAIL: it healed into the shared home"; fail=1; }
done

[ $fail -eq 0 ] || exit 1
echo "PASS: $NAME puts itself back together, whatever is taken from it"
