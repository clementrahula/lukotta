#!/bin/bash
# Assemble the complete corresponding source for a Lukotta release.
#
# Lukotta is conveyed over a network, so GPL-3 section 6(d) and the equivalent
# paragraph of GPL-2 section 3 apply: the source must be offered from the same
# place as the binary. This produces the archive that goes next to the .dmg.
#
#   ./scripts/collect-sources.sh [outdir]
#
# Anything that cannot be fetched is reported and the script exits non-zero.
# A release must not go out with an incomplete source archive.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$HERE/dist/sources}"
VERSION="$(tr -d ' \n' < "$HERE/VERSION")"
DB="$HERE/vendor/engine/alpine/packages.db"

ANYLINUXFS_VER="0.19.0"
LOCK="$HERE/vendor/engine.lock"
lockfield() { /usr/bin/python3 -c "import json;d=json.load(open('$LOCK'));print(d['$1']['$2'])"; }
ALPINE_TAG="v3.24.1"   # the exact release the image was built from

[ -f "$DB" ] || { echo "error: no $DB — run ./vendor-engine.sh first" >&2; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT/alpine"
MANIFEST="$OUT/MANIFEST.txt"
FAILED="$OUT/.failed"
: > "$MANIFEST"; : > "$FAILED"

note() { printf '%s\n' "$1" >> "$MANIFEST"; }

# Half a gigabyte of source, nearly all of it the same bytes as last time: the
# kernel, gcc, every Alpine tarball. Downloading it again for every release is
# an hour of somebody's afternoon and other people's bandwidth for nothing.
#
# So anything named by a version or a tag — which is nearly all of it — is kept
# here and taken from here next time. The key is the URL, so a dependency that
# moves has a new URL and is fetched afresh; nothing else is. What is stored is
# checked against the digest written beside it when it went in, so a cache entry
# that was truncated by a full disk is refetched rather than shipped.
CACHE="${LUKOTTA_SOURCE_CACHE:-$HERE/vendor/.cache/sources}"
mkdir -p "$CACHE"

# printf, not a here-string: a here-string appends a newline, and the Alpine
# collector hashes the URL without one. The two halves of the same cache have
# to agree on the key or each stores what the other cannot find.
cache_key() { printf '%s' "$1" | /usr/bin/shasum -a 256 | awk '{print $1}'; }
digest() { /usr/bin/shasum -a 256 "$1" | awk '{print $1}'; }

# fetch <url> <dest> [fresh]
#
# "fresh" is for a URL that names a branch rather than a version: its contents
# change under the same name, so a stored copy would be last release's source
# claiming to be this one's. Those are the small ones.
fetch() {
  url="$1"; dest="$2"; fresh="${3:-}"
  key="$CACHE/$(cache_key "$url")"

  if [ -z "$fresh" ] && [ -f "$key" ] && [ -f "$key.sha256" ] \
     && [ "$(digest "$key")" = "$(cat "$key.sha256")" ]; then
    if /bin/cp "$key" "$dest"; then
      note "  OK   $(basename "$dest")  <- $url (kept from an earlier release)"
      return
    fi
  fi

  if /usr/bin/curl --fail --location --silent --show-error --retry 2 \
       --connect-timeout 20 --output "$dest" "$url"; then
    note "  OK   $(basename "$dest")  <- $url"
    if [ -z "$fresh" ] && /bin/cp "$dest" "$key.part" 2>/dev/null; then
      digest "$key.part" > "$key.sha256" && /bin/mv "$key.part" "$key"
    fi
  else
    rm -f "$key.part"
    note "  FAIL $(basename "$dest")  <- $url"
    printf '%s\n' "$url" >> "$FAILED"
  fi
}

note "Complete corresponding source for Lukotta $VERSION"
note "Generated $(date -u '+%Y-%m-%d %H:%M UTC')"
note ""

# --- 1. Lukotta itself -----------------------------------------------------
note "Lukotta (GPL-3.0-or-later)"
git -C "$HERE" archive --format=tar.gz --prefix="lukotta-$VERSION/" HEAD \
  -o "$OUT/lukotta-$VERSION.tar.gz" && note "  OK   lukotta-$VERSION.tar.gz (git HEAD)"
note ""

# --- 2. anylinuxfs ---------------------------------------------------------
note "anylinuxfs $ANYLINUXFS_VER (GPL-3.0-or-later)"
fetch "https://github.com/nohajc/anylinuxfs/archive/refs/tags/v${ANYLINUXFS_VER}.tar.gz" \
      "$OUT/anylinuxfs-${ANYLINUXFS_VER}.tar.gz"

# anylinuxfs is shipped modified, so the modifications form part of the
# corresponding source along with the original. The patches are also inside the
# Lukotta archive above and are copied out here so that they sit beside the
# tarball they apply to.
if [ -d "$HERE/patches" ]; then
  mkdir -p "$OUT/anylinuxfs-patches"
  cp "$HERE"/patches/*.patch "$HERE/patches/README.md" "$OUT/anylinuxfs-patches/" 2>/dev/null
  for p in "$OUT"/anylinuxfs-patches/*.patch; do
    [ -e "$p" ] && note "  OK   anylinuxfs-patches/$(basename "$p")  <- this repository"
  done
  note "       apply with: patch -p1 -d anylinuxfs-${ANYLINUXFS_VER} < <patch>"
  note "       the imago- and krun-devices- patches apply to those crates instead"
fi
note ""

# The two patched crates the host binary links in. They are compiled into the
# shipped binary, so their source and the changes to it belong in the
# corresponding source as much as anylinuxfs's does.
for crate in imago krun-devices; do
  cver="$(lockfield "$crate" version)"
  note "$crate $cver ($(lockfield "$crate" licence)), linked into the engine and patched"
  fetch "$(lockfield "$crate" source_url)" "$OUT/$crate-$cver.crate"
done
note ""

# --- 3. libkrun, libkrunfw and the other embedded programs -----------------
# These are distributed inside the engine, so their source travels with it.
note "libkrun and libkrunfw (GPL-2.0-only AND LGPL-2.1-only)"
fetch "https://github.com/containers/libkrun/archive/refs/heads/main.tar.gz" \
      "$OUT/libkrun.tar.gz" fresh
fetch "https://github.com/containers/libkrunfw/archive/refs/heads/main.tar.gz" \
      "$OUT/libkrunfw.tar.gz" fresh
note ""

# libblkid is the one library the engine links from outside its own build, and
# it is LGPL, so shipping it obliges an offer of its source. The version comes
# from the same lock that decides which build is vendored, so it cannot drift
# from what is in the app.
UTIL_VER="$(/usr/bin/python3 -c "import json;print(json.load(open('$HERE/vendor/engine.lock'))['util_linux']['version'])" 2>/dev/null || echo "")"
if [ -n "$UTIL_VER" ]; then
  note "util-linux $UTIL_VER (LGPL-2.1-or-later), source of the bundled libblkid"
  UTIL_SERIES="$(printf '%s' "$UTIL_VER" | cut -d. -f1-2)"
  fetch "https://cdn.kernel.org/pub/linux/utils/util-linux/v${UTIL_SERIES}/util-linux-${UTIL_VER}.tar.xz" \
        "$OUT/util-linux-${UTIL_VER}.tar.xz"
fi

note "gvisor-tap-vsock (gvproxy) and vmnet-helper (Apache-2.0)"
fetch "https://github.com/containers/gvisor-tap-vsock/archive/refs/heads/main.tar.gz" \
      "$OUT/gvisor-tap-vsock.tar.gz" fresh
fetch "https://github.com/nirs/vmnet-helper/archive/refs/heads/main.tar.gz" \
      "$OUT/vmnet-helper.tar.gz" fresh
note ""

# --- 4. Linux kernel bundled by libkrunfw ---------------------------------
# The kernel version is taken from the module directory inside the guest image.
KVER="$(/usr/bin/tar -tzf "$HERE/vendor/engine/alpine/rootfs.tar.gz" 2>/dev/null \
        | sed -n 's|.*lib/modules/\([0-9][^/]*\)/.*|\1|p' | head -1)"
KVER="${KVER:-unknown}"
note "Linux kernel $KVER (GPL-2.0-only), bundled via libkrunfw"
if [ "$KVER" != "unknown" ]; then
  MAJOR="${KVER%%.*}"
  fetch "https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/linux-${KVER}.tar.xz" \
        "$OUT/linux-${KVER}.tar.xz"
else
  note "  FAIL could not determine the kernel version from the guest image"
  echo "kernel-version-unknown" >> "$FAILED"
fi
note ""

# --- 5. Alpine packages ----------------------------------------------------
# GPL-2's same-place paragraph has no third-party-server allowance, so the
# GPL-2 components are mirrored here rather than linked.
note "Alpine packages shipped in the guest image"
note "  The apk database records each binary package's origin, so the shipped"
note "  packages resolve to fewer source packages. For each, the build recipe"
note "  and the upstream tarballs it names are mirrored here — GPL-2's"
note "  same-place paragraph has no third-party-server allowance."
if /usr/bin/python3 "$HERE/scripts/collect_alpine_sources.py" \
     "$DB" "$OUT/alpine" "$ALPINE_TAG" "$CACHE" >> "$MANIFEST" 2>&1; then
  note "  Alpine sources complete."
else
  note "  FAIL Alpine source collection reported problems (see above)."
  echo "alpine-sources" >> "$FAILED"
fi
note ""

if [ -s "$FAILED" ]; then
  note "INCOMPLETE — $(wc -l < "$FAILED" | tr -d ' ') item(s) could not be fetched."
  echo "error: source collection incomplete; see $MANIFEST" >&2
  cat "$MANIFEST"
  exit 1
fi
note "Complete."
rm -f "$FAILED"
printf 'Sources collected in %s (%s)\n' "$OUT" "$(du -sh "$OUT" | awk '{print $1}')"
