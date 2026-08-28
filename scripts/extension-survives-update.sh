#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
# Does the filesystem extension survive the application being replaced?
#
#   ./scripts/extension-survives-update.sh
#
# This is the question that decides whether the v2 route can ship. The module
# has to be enabled once by hand in System Settings, and Apple's own forums
# carry reports that an update re-registers the appex under a new UUID while the
# system still holds the old one -- after which the extension is not recognised
# until somebody toggles it off and on again. A drive that stops opening after
# an ordinary update, until somebody finds a switch they were never told about,
# is a worse failure than the one v2 exists to fix.
#
# Sparkle replaces the bundle: it puts a new copy where the old one was. That
# replacement is the whole of what this reproduces, without a feed, an appcast
# or a release -- so it can be run any time, against the v2 channel only, and it
# publishes nothing.
#
# It touches "Lukotta v2.app" and nothing else. The released and pre-release
# applications are not read, not written and not looked at.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 1

APP="/Applications/Lukotta v2.app"
APPEX_ID="com.lukotta.v2.fs"

state() { # what the system currently believes about the module
  /usr/bin/pluginkit -m -i "$APPEX_ID" -vvv 2>/dev/null
}
uuid() { state | /usr/bin/awk '/UUID/ {print $3; exit}'; }
registered() { state | /usr/bin/grep -c "$APPEX_ID" 2>/dev/null || echo 0; }
# pluginkit marks a plug-in it considers usable with a leading "+".
marked() { state | /usr/bin/head -1 | /usr/bin/cut -c1-1; }

[ -d "$APP" ] || { echo "error: no $APP; build and install the v2 channel first" >&2; exit 1; }

printf 'before the update\n'
printf '  registered   %s\n' "$(registered)"
printf '  uuid         %s\n' "$(uuid)"
printf '  mark         %s\n' "$(marked)"
BEFORE_UUID="$(uuid)"

printf '\nbuilding a second version, as an update would carry\n'
# A different build number, because that is what makes it a different version to
# everything that compares them. LUKOTTA_BUILD is what the update harness uses
# for the same reason: two builds of one tree are otherwise identical.
NEXT_BUILD="$(( $(git rev-list --count HEAD) + 1 ))"
LUKOTTA_INSTALL=0 LUKOTTA_SKIP_TESTS=1 LUKOTTA_BRANDING=v2 \
  LUKOTTA_BUILD="$NEXT_BUILD" ./build-app.sh >/dev/null 2>&1 \
  || { echo "error: the v2 build failed" >&2; exit 1; }
printf '  built build %s\n' "$NEXT_BUILD"

printf '\nreplacing the installed copy, the way Sparkle does\n'
# ditto over the top, which is what an updater does: same path, new contents.
/usr/bin/ditto "$HERE/dist/Lukotta v2.app" "$APP" || exit 1
/usr/bin/touch "$APP"
/bin/sleep 3

printf '\nafter the update, with nothing re-registered by hand\n'
printf '  registered   %s\n' "$(registered)"
printf '  uuid         %s\n' "$(uuid)"
printf '  mark         %s\n' "$(marked)"
AFTER_UUID="$(uuid)"

printf '\n'
if [ "$(registered)" = "0" ]; then
  printf 'RESULT  the extension is not registered at all after an update.\n'
elif [ "$BEFORE_UUID" != "$AFTER_UUID" ]; then
  printf 'RESULT  the extension survived, under a NEW uuid.\n'
  printf '        %s -> %s\n' "$BEFORE_UUID" "$AFTER_UUID"
  printf '        This is the failure Apple forum 788609 describes: whatever was\n'
  printf '        enabled was enabled against the old identifier.\n'
else
  printf 'RESULT  the extension survived with the same uuid.\n'
fi
printf '\nA mount attempt says whether it is usable, which registration does not:\n'
printf '    mount -F -t lukottafs <device> <point>\n'
