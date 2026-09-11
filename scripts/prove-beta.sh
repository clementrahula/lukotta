#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Proves a published beta as its owner uses it: in-app update, then BitLocker and NTFS opened, written, read and deleted in Finder.
#   ./scripts/prove-beta.sh <beta version> <bitlocker partition> <ntfs volume>
#   ./scripts/prove-beta.sh 1.22.20-beta.1 /dev/disk4s1 /dev/disk5
# The only writer of releases/proofs/<beta>.log and releases/BETA-PROVEN, which ship.sh release requires.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 2
USAGE="usage: prove-beta.sh <beta version> <bitlocker partition> <ntfs volume>"
BETA="${1:?$USAGE}"; BITLOCKER="${2:?$USAGE}"; NTFS="${3:?$USAGE}"
[[ "$BETA" =~ ^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$ ]] || { echo "not a beta version: $BETA" >&2; exit 2; }
APP="/Applications/Lukotta Beta.app"
PROC="Lukotta Beta"
FEED="https://updates.lukotta.com/beta/appcast.xml"
LOG="releases/proofs/$BETA.log"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p releases/proofs "$WORK/read" "$WORK/back"
: > "$WORK/log"

say() { printf '%s\n' "$*" | tee -a "$WORK/log"; }
pass() { say "PASS $*"; }
finish() {
  if [ "$1" = 0 ]; then say "VERDICT $BETA: proven"; else say "VERDICT $BETA: not proven"; fi
  cp "$WORK/log" "$LOG"
  [ "$1" = 0 ] || exit 1
  local digest; digest="$(shasum -a 256 "$LOG" | cut -c1-12)"
  { grep -v "^$BETA " releases/BETA-PROVEN 2>/dev/null; echo "$BETA $COMMIT $digest"; } > "$WORK/proven"
  cp "$WORK/proven" releases/BETA-PROVEN
  git add "$LOG" releases/BETA-PROVEN && git commit -q -m "$BETA proven" -- "$LOG" releases/BETA-PROVEN \
    && git push -q origin HEAD
  exit 0
}
fail() { say "FAIL $*"; finish 1; }
now() { date +%s; }
version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null; }

# Accessibility actions through the AX API: nobody clicks, nothing needs the screen.
BUNDLE="com.lukotta.beta"
swiftc -O -o "$WORK/ax-press" scripts/ax-press.swift 2>/dev/null || { echo "ax-press did not build" >&2; exit 2; }
press_id() { "$WORK/ax-press" "$BUNDLE" press "$1" "$2" 2>/dev/null | tail -1; }  # identifier, seconds
shows() { "$WORK/ax-press" "$BUNDLE" shows "$1" "$2" 2>/dev/null | tail -1; }  # text, seconds

# One step of Sparkle's own window: whichever install button it offers, or that nothing is offered.
sparkle_step() {
  local name
  for name in "Install and Relaunch" "Install Update" "Install"; do
    [ "$("$WORK/ax-press" "$BUNDLE" title "$name" 1 2>/dev/null | tail -1)" = pressed ] \
      && { echo "pressed $name"; return; }
  done
  for name in "up to date" "up-to-date"; do
    [ "$("$WORK/ax-press" "$BUNDLE" shows "$name" 1 2>/dev/null | tail -1)" = shown ] \
      && { echo uptodate; return; }
  done
  echo waiting
}

finder() {  # copy <from> <to> | delete <item> | eject <volume>
  osascript - "$@" <<'APPLESCRIPT' 2>&1
on run argv
  tell application "Finder"
    with timeout of 86400 seconds
      if item 1 of argv is "copy" then
        duplicate (every item of (POSIX file (item 2 of argv) as alias)) to (POSIX file (item 3 of argv) as alias) with replacing
      else if item 1 of argv is "delete" then
        delete (POSIX file (item 2 of argv) as alias)
      else
        eject (POSIX file (item 2 of argv) as alias)
      end if
    end timeout
  end tell
end run
APPLESCRIPT
}

# Where Finder shows the device, not the hidden mount beneath it.
point_of() {
  mount | grep -F "$(basename "$1").local" | grep -v nobrowse | head -1 | sed -E 's/^.* on (.*) \([^()]*\)$/\1/'
}
served() { mount | grep -qF "$(basename "$1").local"; }

running_app() {
  open -a "$APP" || return 1
  for _ in $(seq 1 30); do
    [ "$(osascript -e "tell application \"System Events\" to count windows of process \"$PROC\"" 2>/dev/null)" -gt 0 ] \
      2>/dev/null && return 0
    sleep 1
  done
  return 1
}

open_drive() {  # kind, device, step
  local t0 mp; t0=$(now)
  running_app || fail "$3: $PROC did not open a window"
  "$WORK/ax-press" "$BUNDLE" title "All Drives" 2 >/dev/null 2>&1
  [ "$(press_id "drive $2" 30)" = pressed ] || fail "$3: $PROC lists no drive at $2"
  if [ "$1" = bitlocker ]; then
    [ "$(shows "Unlock uses it directly" 15)" = shown ] \
      || fail "keys: $PROC offered no saved key for $2; open it once in $PROC with Remember ticked"
  fi
  [ "$(press_id unlock 20)" = pressed ] || fail "$3: no Unlock button for $2"
  for _ in $(seq 1 240); do mp="$(point_of "$2")"; [ -n "$mp" ] && break; sleep 1; done
  [ -n "$mp" ] || fail "$3: $2 did not reach Finder in 240 s"
  pass "$3: $(( $(now) - t0 )) s at $mp"
  OPENED="$mp"
}

eject_drive() {  # kind, device, mount point
  local t0 out; t0=$(now)
  out="$(finder eject "$3")" || fail "$1 eject: Finder refused: $out"
  for _ in $(seq 1 60); do served "$2" || break; sleep 1; done
  served "$2" && fail "$1 eject: $2 still served 60 s after Finder ejected it"
  pass "$1 eject: $(( $(now) - t0 )) s"
}

prove_drive() {  # kind, device
  local kind="$1" dev="$2" name out rc big tree gone mp secs rate prev wb rb tb
  name="$(diskutil info "$dev" 2>/dev/null | awk -F': *' '/Media Name/ {print $2; exit}')"
  open_drive "$kind" "$dev" "$kind open"; mp="$OPENED"

  out="$(MB=1024 FILES=2000 scripts/finder-parity.sh "$mp" 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/    /' | tee -a "$WORK/log"
  big="$(printf '%s\n' "$out" | awk '$1=="big" && $2=="copy" {print $4}')"
  tree="$(printf '%s\n' "$out" | awk '$1=="tree" && $2=="copy" {sub(/s$/,"",$3); print $3}')"
  gone="$(printf '%s\n' "$out" | awk '$1=="tree" && $2=="delete" {sub(/s$/,"",$3); print $3}')"
  [ "$rc" = 0 ] && [ -n "$big" ] && [ -n "$tree" ] || fail "$kind write: Finder's copy or its check failed"
  pass "$kind write: 1024 MB at $big MB/s and 2000 small files in $tree s, every byte identical"
  pass "$kind delete: 2000 small files in $gone s"

  for i in 1 2 3 4; do dd if=/dev/urandom of="$WORK/read/r-$i.bin" bs=1048576 count=128 status=none; done
  if ! { mkdir -p "$mp/prove-read" && ditto "$WORK/read" "$mp/prove-read"; }; then
    fail "$kind read: could not stage 512 MB to read"
  fi
  eject_drive "$kind" "$dev" "$mp"
  open_drive "$kind" "$dev" "$kind reopen"; mp="$OPENED"
  local t0; t0=$(date +%s.%N)
  out="$(finder copy "$mp/prove-read" "$WORK/back")" || fail "$kind read: Finder's copy failed: $out"
  secs=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN {printf "%.1f", b - a}')
  for i in 1 2 3 4; do cmp -s "$WORK/read/r-$i.bin" "$WORK/back/r-$i.bin" || fail "$kind read: r-$i.bin differs"; done
  rate=$(awk -v s="$secs" 'BEGIN {printf "%.1f", 536.870912 / s}')
  pass "$kind read: 512 MB at $rate MB/s, every byte identical"
  finder delete "$mp/prove-read" >/dev/null || rm -rf "$mp/prove-read"
  rm -rf "$mp/.Trashes/$(id -u)/prove-read"* "$WORK/back/"*

  prev="$(/bin/ls releases/proofs/*.log 2>/dev/null | grep -v "/$BETA.log$" | sort -V \
    | xargs grep -h "^PASS $kind speed: .* on $name\$" 2>/dev/null | tail -1)"
  if [ -n "$prev" ]; then read -r wb rb tb <<<"$(awk '{print $5, $9, $13}' <<<"$prev")"; else wb=none rb=none tb=none; fi
  awk -v w="$big" -v wb="$wb" -v r="$rate" -v rb="$rb" -v t="$tree" -v tb="$tb" 'BEGIN {
    if (wb != "none" && w < 0.75 * wb) exit 1
    if (rb != "none" && r < 0.75 * rb) exit 1
    if (tb != "none" && t > 1.5 * tb) exit 1 }' \
    || fail "$kind speed: write $big was $wb read $rate was $rb tree $tree was $tb on $name"
  pass "$kind speed: write $big was $wb read $rate was $rb tree $tree was $tb on $name"
  eject_drive "$kind" "$dev" "$mp"
}

say "prover $(shasum -a 256 scripts/prove-beta.sh | cut -c1-12), $(date -u +%FT%TZ)"
COMMIT="$(git ls-remote --tags origin "refs/tags/v$BETA^{}" | cut -f1)"
[ -n "$COMMIT" ] || COMMIT="$(git ls-remote --tags origin "refs/tags/v$BETA" | cut -f1)"
[ -n "$COMMIT" ] || fail "published: no tag v$BETA on origin"
git fetch -q origin tag "v$BETA" 2>/dev/null
[ "$(gh release view "v$BETA" --json isDraft -q .isDraft 2>/dev/null)" = false ] \
  || fail "published: v$BETA is not a published release"
top="$(curl -fsS "$FEED" | grep -oE 'shortVersionString(="|>)[^"<]+' | head -1 | sed -E 's/.*(="|>)//')"
[ "$top" = "$BETA" ] || fail "published: the beta feed offers ${top:-nothing}, not $BETA"
pass "published: v$BETA at ${COMMIT:0:7}, not a draft, newest in the beta feed"

before="$(version)"
[ -n "$before" ] || fail "update: $PROC is not installed"
if [ "$before" = "$BETA" ]; then
  prior="$(grep -h "^PASS update: .* -> $BETA " "$LOG" 2>/dev/null | tail -1)"
  [ -n "$prior" ] || fail "update: $BETA is already installed and no earlier run saw it arrive; install the beta before it"
  say "$prior"
else
  t0=$(now)
  running_app || fail "update: $PROC $before did not open a window"
  osascript -e "tell application \"System Events\" to tell process \"$PROC\" to click menu item \"Check for Updates…\" of menu 1 of menu bar item \"$PROC\" of menu bar 1" >/dev/null 2>&1 \
    || fail "update: $PROC $before has no Check for Updates menu item"
  while [ $(( $(now) - t0 )) -lt 600 ] && [ "$(version)" != "$BETA" ]; do
    step="$(sparkle_step)"
    [ "$step" = uptodate ] && fail "update: $PROC $before says it is up to date"
    sleep 3
  done
  [ "$(version)" = "$BETA" ] || fail "update: still $(version) after 600 s"
  if ! { codesign --verify --deep --strict "$APP" 2>/dev/null && spctl --assess --type execute "$APP" 2>/dev/null; }; then
    fail "update: the installed $BETA is not signed and notarised"
  fi
  pass "update: $before -> $BETA in $(( $(now) - t0 )) s, signed and notarised"
fi

prove_drive bitlocker "$BITLOCKER"
pass "keys: $PROC offered the saved key for $BITLOCKER on both opens"
prove_drive ntfs "$NTFS"

t0=$(now)
osascript -e "tell application \"$PROC\" to quit" >/dev/null 2>&1
for _ in $(seq 1 15); do pgrep -xq "$PROC" || break; sleep 1; done
pgrep -xq "$PROC" && fail "quit: $PROC still running 15 s after being asked to quit"
pass "quit: $(( $(now) - t0 )) s"
finish 0
