#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# What a release has to survive, in about half an hour.
#
#   ./scripts/preflight.sh
#
# scripts/e2e.sh covers everything: every image format, every filesystem a
# fixture can be built for, the names people actually use, the unhappy paths.
# It takes over an hour on each channel and belongs to a night's work.
#
# This is the other thing: the path a person takes, from installing the app to
# using it to updating it, run against both channels, quickly enough that
# nobody skips it before a release. What it leaves out are the many formats --
# one raw image, one NTFS image and one LUKS container stand for the rest,
# because a fault in the VDI driver shows up in the nightly run and a fault in
# opening, writing or updating shows up here.
#
# It ends with both applications installed and working, which is what somebody
# picking up a Mac in the morning wants to find.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 1

CACHE="${LUKOTTA_E2E_CACHE:-$HOME/Library/Caches/dev.lukotta.e2e}"
PASSPHRASE="lukotta-e2e"
SKIP_BUILD="${LUKOTTA_PREFLIGHT_SKIP_BUILD:-0}"

pass=0; fail=0
started="$(date +%s)"
say()  { printf '\n== %s\n' "$1"; }
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }
that() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

# Anything left running from whatever ran last. A machine still serving a mount
# nobody remembers is the commonest reason a run fails for the wrong reason.
tidy() {
  for point in "$HOME"/Volumes/*; do
    [ -d "$point" ] || continue
    /sbin/umount -f "$point" >/dev/null 2>&1 || true
    rmdir "$point" >/dev/null 2>&1 || true
  done
  pkill -f "Contents/Resources/engine/anylinuxfs" >/dev/null 2>&1 || true
}

say "Building both channels"
if [ "$SKIP_BUILD" = "1" ]; then
  printf '  ..   skipped; using what is installed\n'
else
  for branding in official beta; do
    if LUKOTTA_DEVTOOLS=1 LUKOTTA_BRANDING="$branding" ./build-app.sh >/dev/null 2>&1; then
      ok "the $branding build is made, signed and installed"
    else
      bad "the $branding build is made, signed and installed"
    fi
  done
fi

RELEASE="/Applications/Lukotta.app"
BETA="/Applications/Lukotta Beta.app"
for app in "$RELEASE" "$BETA"; do
  that "$(basename "$app" .app) starts" "$app/Contents/MacOS/$(basename "$app" .app)" --smoke-test
done

# The version and build both channels are carrying, said out loud: a release cut
# from the wrong tree is easier to see here than to work out afterwards.
for app in "$RELEASE" "$BETA"; do
  printf '  ..   %s is %s (build %s)\n' "$(basename "$app" .app)" \
    "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")" \
    "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")"
done

say "A day's use, on both channels"
# One raw image, one NTFS image, one LUKS container: opening, writing, ejecting,
# opening again. The nightly run is what covers the other nine formats.
for app in "$RELEASE" "$BETA"; do
  name="$(basename "$app" .app)"
  tidy
  identifier="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")"
  export ANYLINUXFS_HOME="$HOME/Library/Application Support/$identifier/engine"
  log="$(mktemp)"
  LUKOTTA_E2E_QUICK=1 "$app/Contents/MacOS/$name" --e2e \
    container="$CACHE/container.img" passphrase="$PASSPHRASE" \
    plain="$CACHE/plain.img" ntfs="$CACHE/plain.ntfs.img" >"$log" 2>&1
  steps="$(grep -c '^  ok' "$log" || true)"
  broke="$(grep -c '^  FAIL' "$log" || true)"
  if [ "${broke:-0}" -eq 0 ]; then
    ok "$name opens, writes to and ejects a drive ($steps checks)"
  else
    bad "$name opens, writes to and ejects a drive ($broke of $((steps + broke)) failed)"
    grep -B 2 '^  FAIL' "$log" | tail -12 | sed 's/^/      /'
  fi
  rm -f "$log"
done
tidy

say "An update, and a version that will not start"
# The whole update path against the beta: a fresh install, an update applied for
# real, the same again as a delta, an update offered while a drive is open, and
# a build that cannot run being put back. Nothing about it is simulated.
if [ "${LUKOTTA_PREFLIGHT_SKIP_UPDATE:-0}" = "1" ]; then
  printf '  ..   skipped\n'
else
  log="$(mktemp)"
  if ./scripts/update-test.sh >"$log" 2>&1; then
    ok "$(grep 'checks passed' "$log" | tail -1)"
  else
    bad "the update path: $(grep 'checks passed' "$log" | tail -1)"
    grep -B 2 '^  FAIL' "$log" | tail -20 | sed 's/^/      /'
  fi
  rm -f "$log"
fi

say "What each channel keeps to itself"
for identifier in com.lukotta com.lukotta.beta; do
  that "$identifier has a directory of its own" \
    test -d "$HOME/Library/Application Support/$identifier"
done
that "and neither has taken over the other's engine" \
  test ! -e "$HOME/Library/Application Support/com.lukotta/engine/.anylinuxfs/alpine/rootfs.ver.beta"

say "What a person downloads"
DMG="$(mktemp -d)/Lukotta.dmg"
VERSION="$(tr -d ' \n' < VERSION)"
if ./scripts/make-dmg.sh "$RELEASE" "$DMG" "Lukotta" "$VERSION" >/dev/null 2>&1; then
  ok "the disk image is built"
  that "and verifies" /usr/bin/hdiutil verify "$DMG"
  point="$(/usr/bin/hdiutil attach "$DMG" -nobrowse -readonly 2>/dev/null | awk -F'\t' '/Volumes/{print $NF}' | tail -1)"
  if [ -n "$point" ]; then
    that "the app inside it is signed" /usr/bin/codesign --verify --deep --strict "$point/Lukotta.app"
    that "and starts from the image" "$point/Lukotta.app/Contents/MacOS/Lukotta" --smoke-test
    /usr/bin/hdiutil detach "$point" >/dev/null 2>&1 || true
  else
    bad "the disk image mounts"
  fi
else
  bad "the disk image is built"
fi
rm -rf "$(dirname "$DMG")"

tidy
printf '\n%s/%s passed, in %s minutes\n' "$pass" "$((pass + fail))" \
  "$(( ($(date +%s) - started + 30) / 60 ))"
[ "$fail" = "0" ]
