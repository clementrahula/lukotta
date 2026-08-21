#!/bin/bash
# Fetch the engine Lukotta ships, exactly as vendor/engine.lock pins it.
#
# Staging the engine from whatever anylinuxfs happens to be installed on the
# build machine makes the build unreproducible, and silently sets the lowest
# macOS the app will run on: a library picked up from a macOS 26 machine carries
# a macOS 26 minimum into the bundle, while anylinuxfs itself supports macOS 11.
#
# Everything here is downloaded from a pinned URL and checked against a pinned
# sha256. A mismatch stops the build rather than shipping something unexamined.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$HERE/vendor/engine.lock"
CACHE="${LUKOTTA_ENGINE_CACHE:-$HERE/vendor/.cache}"
OUT="${1:-$HERE/vendor/upstream}"

[ -f "$LOCK" ] || { echo "error: no $LOCK" >&2; exit 1; }

field() { /usr/bin/python3 -c "import json,sys;d=json.load(open('$LOCK'));print(d['$1']['$2'])"; }

# Homebrew pulls ghcr.io anonymously with this fixed token; it is not a secret
# and not tied to any account.
fetch() {  # url sha256 destination
  local url="$1" want="$2" dest="$3" got
  if [ -f "$dest" ]; then
    got="$(/usr/bin/shasum -a 256 "$dest" | awk '{print $1}')"
    [ "$got" = "$want" ] && { echo "  cached  $(basename "$dest")"; return 0; }
    rm -f "$dest"
  fi
  echo "  fetch   $(basename "$dest")"
  /usr/bin/curl -fsSL --max-time 900 -H "Authorization: Bearer QQ==" -o "$dest" "$url"
  got="$(/usr/bin/shasum -a 256 "$dest" | awk '{print $1}')"
  [ "$got" = "$want" ] || {
    rm -f "$dest"
    echo "error: checksum mismatch for $url" >&2
    echo "  expected $want" >&2
    echo "  got      $got" >&2
    exit 1; }
  echo "          sha256 verified"
}

mkdir -p "$CACHE"
rm -rf "$OUT"; mkdir -p "$OUT"

echo "anylinuxfs $(field anylinuxfs version) ($(field anylinuxfs bottle_tag))"
fetch "$(field anylinuxfs bottle_url)" "$(field anylinuxfs bottle_sha256)" "$CACHE/anylinuxfs.tar.gz"
echo "util-linux $(field util_linux version)"
fetch "$(field util_linux bottle_url)" "$(field util_linux bottle_sha256)" "$CACHE/util-linux.tar.gz"

echo "Unpacking…"
/usr/bin/tar -xzf "$CACHE/anylinuxfs.tar.gz" -C "$OUT"
/usr/bin/tar -xzf "$CACHE/util-linux.tar.gz" -C "$OUT"

ENGINE="$OUT/anylinuxfs/$(field anylinuxfs version)"
[ -x "$ENGINE/bin/anylinuxfs" ] || { echo "error: no engine in the bottle" >&2; exit 1; }

printf 'Fetched into %s\n' "$OUT"
printf '  engine     %s\n' "$ENGINE"
printf '  util-linux %s\n' "$OUT/util-linux/$(field util_linux version)"
