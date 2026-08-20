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
ALPINE_TAG="v3.24.1"   # the exact release the image was built from

[ -f "$DB" ] || { echo "error: no $DB — run ./vendor-engine.sh first" >&2; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT/alpine"
MANIFEST="$OUT/MANIFEST.txt"
FAILED="$OUT/.failed"
: > "$MANIFEST"; : > "$FAILED"

note() { printf '%s\n' "$1" >> "$MANIFEST"; }
fetch() {
  url="$1"; dest="$2"
  if /usr/bin/curl --fail --location --silent --show-error --retry 2 \
       --connect-timeout 20 --output "$dest" "$url"; then
    note "  OK   $(basename "$dest")  <- $url"
  else
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
note ""

# --- 3. libkrun, libkrunfw and the other embedded programs -----------------
# These are distributed inside the engine, so their source travels with it.
note "libkrun and libkrunfw (GPL-2.0-only AND LGPL-2.1-only)"
fetch "https://github.com/containers/libkrun/archive/refs/heads/main.tar.gz" \
      "$OUT/libkrun.tar.gz"
fetch "https://github.com/containers/libkrunfw/archive/refs/heads/main.tar.gz" \
      "$OUT/libkrunfw.tar.gz"
note ""

note "gvisor-tap-vsock (gvproxy) and vmnet-helper (Apache-2.0)"
fetch "https://github.com/containers/gvisor-tap-vsock/archive/refs/heads/main.tar.gz" \
      "$OUT/gvisor-tap-vsock.tar.gz"
fetch "https://github.com/nirs/vmnet-helper/archive/refs/heads/main.tar.gz" \
      "$OUT/vmnet-helper.tar.gz"
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
     "$DB" "$OUT/alpine" "$ALPINE_TAG" >> "$MANIFEST" 2>&1; then
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
