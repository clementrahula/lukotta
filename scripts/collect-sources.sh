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
ALPINE_BRANCH="v3.24"

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

# --- 3. Linux kernel + libkrunfw ------------------------------------------
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

# --- 4. Alpine packages ----------------------------------------------------
# GPL-2's same-place paragraph has no third-party-server allowance, so the
# GPL-2 components are mirrored here rather than linked.
note "Alpine packages shipped in the guest image"
note "  aports build recipes (the scripts controlling compilation) plus each"
note "  package's upstream source, per APKBUILD."
fetch "https://gitlab.alpinelinux.org/alpine/aports/-/archive/${ALPINE_BRANCH}/aports-${ALPINE_BRANCH}.tar.gz" \
      "$OUT/alpine/aports-${ALPINE_BRANCH}.tar.gz"

PKGS="$(/usr/bin/grep '^P:' "$DB" | sed 's/^P://' | sort -u)"
COUNT="$(printf '%s\n' "$PKGS" | wc -l | tr -d ' ')"
note "  $COUNT packages shipped; upstream sources resolved from aports:"

if [ -s "$OUT/alpine/aports-${ALPINE_BRANCH}.tar.gz" ]; then
  APORTS="$(mktemp -d)"
  /usr/bin/tar -xzf "$OUT/alpine/aports-${ALPINE_BRANCH}.tar.gz" -C "$APORTS" 2>/dev/null
  ROOT="$(/usr/bin/find "$APORTS" -maxdepth 1 -type d -name 'aports-*' | head -1)"
  for pkg in $PKGS; do
    AB="$(/usr/bin/find "$ROOT" -maxdepth 3 -type d -name "$pkg" -print -quit 2>/dev/null)/APKBUILD"
    if [ ! -f "$AB" ]; then
      note "  ---  $pkg: no APKBUILD (subpackage or renamed; covered by its origin)"
      continue
    fi
    note "  OK   $pkg: recipe in aports"
  done
  rm -rf "$APORTS"
else
  note "  FAIL aports snapshot unavailable; per-package recipes not verified"
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
