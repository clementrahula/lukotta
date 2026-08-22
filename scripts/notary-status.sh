#!/bin/bash
# Say whether notarisation is set up on this machine — correctly.
#
#   ./scripts/notary-status.sh
#
# There is one way to get this wrong and it has been got wrong. `xcrun` resolves
# through whatever `xcode-select` points at; pointed at the Command Line Tools
# it finds a copy of notarytool that cannot read credentials stored in the Local
# Items keychain, and answers
#
#     Error: No Keychain password item found for profile: …
#
# for a profile that exists and works. Searching the keychain by hand with
# `security find-generic-password` cannot see those credentials either. Both
# look exactly like "notarisation was never set up".
#
# So this script never reports absence it cannot prove. It finds a copy of
# notarytool that can read the credential, and where it cannot find one it says
# it does not know, rather than saying no.
set -euo pipefail

PROFILE="${LUKOTTA_NOTARY_PROFILE:-lukotta}"

# Xcode's copy first, then whatever the environment resolves to. Only the first
# can read every kind of stored credential.
XCODE_NOTARYTOOL="/Applications/Xcode.app/Contents/Developer/usr/bin/notarytool"
if [ -x "$XCODE_NOTARYTOOL" ]; then
  NOTARYTOOL="$XCODE_NOTARYTOOL"
  CAN_READ_ALL=1
else
  NOTARYTOOL="$(/usr/bin/xcrun -f notarytool 2>/dev/null || true)"
  case "$NOTARYTOOL" in
    */Xcode.app/*) CAN_READ_ALL=1 ;;
    *) CAN_READ_ALL=0 ;;
  esac
fi

if [ -z "$NOTARYTOOL" ]; then
  echo "unknown: no notarytool on this machine."
  echo "  Install Xcode, then run this again."
  exit 2
fi

echo "notarytool: $NOTARYTOOL"
echo "profile:    $PROFILE"

# A locked screen locks the Local Items keychain with it, and a credential
# stored there then reads exactly like one that was never stored. This is the
# same error by a different cause, so it is reported as not knowing.
LOCKED=0
if /usr/bin/python3 -c '
import plistlib, subprocess, sys
out = subprocess.run(["ioreg", "-n", "Root", "-d1", "-a"], capture_output=True).stdout
sys.exit(0 if plistlib.loads(out).get("IOConsoleLocked") else 1)
' 2>/dev/null; then
  LOCKED=1
fi

OUT="$("$NOTARYTOOL" history --keychain-profile "$PROFILE" 2>&1 | head -3 || true)"

case "$OUT" in
  *"Successfully received submission history"*)
    echo "configured: yes. The credential works and Apple answered."
    exit 0
    ;;
  *"No Keychain password item"*)
    if [ "$LOCKED" = "1" ]; then
      echo "unknown: the screen is locked, and a credential in the Local Items"
      echo "  keychain cannot be read while it is. This is what a missing"
      echo "  credential looks like as well. Unlock the Mac and ask again."
      exit 2
    fi
    if [ "$CAN_READ_ALL" = "1" ]; then
      echo "configured: no credential named \"$PROFILE\" on this machine."
      echo "  Store one with: $NOTARYTOOL store-credentials \"$PROFILE\" …"
      echo "  Or name another with LUKOTTA_NOTARY_PROFILE, or use an App Store"
      echo "  Connect key or an Apple ID; build-app.sh takes any of them."
      exit 1
    fi
    echo "unknown: this copy of notarytool cannot read credentials stored in the"
    echo "  Local Items keychain, so it cannot tell a missing credential from one"
    echo "  it is unable to see. Do not conclude that notarisation is unconfigured."
    echo "  Install Xcode, or point at it:"
    echo "    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"
    exit 2
    ;;
  *)
    # Something else: no network, Apple down, an expired credential. Whatever it
    # is, it is not "never set up", so it is not reported as that.
    echo "unknown: notarytool answered with something else."
    printf '%s\n' "$OUT" | sed 's/^/  /'
    exit 2
    ;;
esac
