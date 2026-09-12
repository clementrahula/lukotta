#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# A drive with no password is never asked for one, and never offered another drive's.
#   ./scripts/no-other-drives-password.sh <encrypted device> <plain device>
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
ENCRYPTED="${1:?usage: no-other-drives-password.sh <encrypted device> <plain device>}"
PLAIN="${2:?usage: no-other-drives-password.sh <encrypted device> <plain device>}"
APP="/Applications/Lukotta Dev.app"
BUNDLE="com.lukotta.dev"
[ -d "$APP" ] || { echo "no dev build at $APP"; exit 2; }
WORK="$(mktemp -d)"
trap 'pkill -x "Lukotta Dev"; rm -rf "$WORK"' EXIT
swiftc -O -o "$WORK/ax-press" "$(dirname "$0")/ax-press.swift" 2>/dev/null || { echo "ax-press did not build"; exit 2; }
ax() { "$WORK/ax-press" "$BUNDLE" "$@" | tail -n 1; }

pkill -x "Lukotta Dev"; sleep 2
open -a "$APP"; sleep 6

# The encrypted drive first, so a saved key is on screen and in hand.
[ "$(ax press "drive $ENCRYPTED" 30)" = pressed ] || { echo "no row for $ENCRYPTED"; exit 1; }
offered="$(ax shows "Unlock uses it directly" 15)"
echo "$ENCRYPTED offers its saved key: $offered"

# Then the drive that has no password at all, from the list this goes back to.
[ "$(ax press back 15)" = pressed ] || [ "$(ax title "All Drives" 5)" = pressed ] \
  || { echo "no way back to the list"; exit 1; }
back=""
for _ in $(seq 1 20); do
  [ "$(ax press "drive $PLAIN" 1)" = pressed ] && { back=pressed; break; }
  sleep 1
done
[ "$back" = pressed ] || { echo "no row for $PLAIN"; exit 1; }
sleep 2
carried="$(ax shows "Unlock uses it directly" 3)"
asked="$(ax shows "passphrase" 3)"
asked2="$(ax shows "password, or its 48-digit recovery key" 3)"
echo "$PLAIN carries the other drive's saved key: $carried; is asked for a passphrase: $asked; for a password: $asked2"
[ "$offered" = shown ] && [ "$carried" != shown ] && [ "$asked" != shown ] && [ "$asked2" != shown ]
