#!/bin/bash
# Does each application keep to its own Linux environment?
#
# A pre-release was found unpacking one into ~/.anylinuxfs -- the directory
# every program using this engine shares -- while its own, already unpacked,
# sat unused. Two applications sharing one environment is two applications that
# one update breaks at once, and it is why a drive would not open: every attempt
# re-initialised a guest in the wrong place and then stopped without mounting.
#
# Nothing here exports ANYLINUXFS_HOME. That is the whole point. preflight.sh
# and first-run-open.sh both export it before launching, which is to say they
# hand the app the one thing it has to supply for itself -- so neither of them
# could ever fail on this, and neither did.
set -uo pipefail
SHARED="$HOME/.anylinuxfs"

fail=0
aside=""
if [ -d "$SHARED" ]; then
  aside="$SHARED.aside.$$"
  mv "$SHARED" "$aside" || { echo "could not move the shared home aside"; exit 2; }
fi
restore() {
  if [ -n "$aside" ] && [ -d "$aside" ]; then rm -rf "$SHARED"; mv "$aside" "$SHARED"; fi
}
trap restore EXIT

for app in "/Applications/Lukotta.app" "/Applications/Lukotta Beta.app" \
           "/Applications/Lukotta Dev.app" "/Applications/Drive Unlocker.app"; do
  [ -d "$app" ] || continue
  name="$(basename "$app" .app)"
  identifier="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)"
  own="$HOME/Library/Application Support/$identifier/engine/.anylinuxfs"

  # Launching it is enough: what is being asked is whether anything it does
  # reaches for the shared directory, not whether a drive opens.
  # Bounded. --check-helper talks to a privileged daemon over XPC and one of
  # the applications installed here never came back from it: a full gate sat on
  # this line for forty-nine minutes with no process of its own running, and
  # everything queued behind it never ran. What is being asked is whether the
  # launch reaches for the shared directory, and thirty seconds is long past
  # enough to find out.
  timeout 30 env -u ANYLINUXFS_HOME "$app/Contents/MacOS/$name" \
    --check-helper >/dev/null 2>&1
  sleep 1

  if [ -d "$SHARED" ]; then
    echo "FAIL: $name made $SHARED"
    rm -rf "$SHARED"
    fail=1
  else
    echo "ok   $name kept to its own"
  fi
  [ -n "$identifier" ] && echo "       its own is $own"
done

[ $fail -eq 0 ] || exit 1
echo "PASS: every application here keeps to its own Linux environment"
