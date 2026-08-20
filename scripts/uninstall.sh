#!/bin/bash
# Remove Lukotta and everything it left behind.
#
#   ./scripts/uninstall.sh            say what would be removed, remove nothing
#   ./scripts/uninstall.sh --remove   actually remove it
#
# Dragging the app to the Bin does not unregister the privileged helper, which
# is a launchd daemon and stays registered without an app to serve. Nothing here
# needs an administrator password: the daemon is unregistered through the same
# service the app registered it with.
set -euo pipefail
APP="/Applications/Lukotta.app"
DAEMON="com.clementrahula.lukotta.helper"
GUEST="$HOME/.anylinuxfs"
SUPPORT="$HOME/Library/Application Support/Lukotta"
DOMAIN="com.clementrahula.lukotta"
KEYCHAIN_SERVICE="dev.lukotta.drive-credential"

DO_IT=0
[ "${1:-}" = "--remove" ] && DO_IT=1
[ "$DO_IT" = "1" ] || echo "Dry run. Nothing will be removed; pass --remove to do it."
echo

act() {  # verb, description, command...
  local verb="$1" what="$2"; shift 2
  if [ "$DO_IT" = "1" ]; then
    echo "  ${verb}ing $what"
    "$@" >/dev/null 2>&1 || true
  else
    echo "  would $verb $what"
  fi
}

# Unmount anything still open, so no drive is left pointing at a dead server.
ENGINE="$APP/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs"
if [ -x "$ENGINE" ]; then
  "$ENGINE" status 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="on") print $(i+1)}' | while read -r point; do
    [ -n "$point" ] || continue
    act eject "the drive at $point" "$ENGINE" unmount "$point" --wait-for-vm 30
  done
fi

# The daemon first: an app removed while it is still registered leaves launchd
# with a service whose program no longer exists.
if /bin/launchctl print "system/$DAEMON" >/dev/null 2>&1; then
  if [ "$DO_IT" = "1" ] && [ -x "$APP/Contents/MacOS/Lukotta" ]; then
    echo "  unregistering the background helper"
    "$APP/Contents/MacOS/Lukotta" --uninstall-helper >/dev/null 2>&1 || \
      echo "    (could not unregister it; remove Lukotta from Login Items in System Settings)"
  else
    echo "  would unregister the background helper"
  fi
else
  echo "  the background helper is not registered"
fi

[ -e "$APP" ] && act remove "$APP" /bin/rm -rf "$APP" || echo "  no app at $APP"
[ -d "$GUEST" ] && act remove "$GUEST (the Linux environment, ~95 MB)" /bin/rm -rf "$GUEST"
[ -d "$SUPPORT" ] && act remove "$SUPPORT" /bin/rm -rf "$SUPPORT"
/usr/bin/defaults read "$DOMAIN" >/dev/null 2>&1 && act remove "preferences ($DOMAIN)" /usr/bin/defaults delete "$DOMAIN"

# Passphrases are the user's, and deleting them silently would be wrong.
if /usr/bin/security find-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
  echo
  echo "Keychain entries for remembered drives are left alone."
  echo "Remove them yourself in Keychain Access, under \"$KEYCHAIN_SERVICE\"."
fi

echo
[ "$DO_IT" = "1" ] && echo "Done." || echo "Nothing was removed. Pass --remove to do it."
