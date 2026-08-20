#!/bin/bash
# Vendor the anylinuxfs runtime into ./vendor/engine so the app can ship it.
#
# The app must not download anything on first run, so every host-side component
# is copied in and made position-independent. Only the pieces actually reachable
# at runtime are taken: the full Homebrew dependency trees are ~60 MB of
# binaries the engine never invokes on the host.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# Staged from a runtime already present on this machine. That is the reason the
# build is not reproducible: see Documentation/TODO.md, stage 1. The default path
# is where an earlier version of this project installed it.
SRC_RUNTIME="${LUKOTTA_SRC_RUNTIME:-$HOME/Library/Application Support/BitLocker Mounter/runtime}"
SRC_ROOTFS="${LUKOTTA_SRC_ROOTFS:-$HOME/.anylinuxfs/alpine}"
OUT="$HERE/vendor/engine"

[ -x "$SRC_RUNTIME/anylinuxfs/bin/anylinuxfs" ] || {
  echo "error: no anylinuxfs runtime at $SRC_RUNTIME" >&2; exit 1; }
[ -d "$SRC_ROOTFS/rootfs" ] || {
  echo "error: no Linux rootfs at $SRC_ROOTFS/rootfs" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/anylinuxfs/lib"

echo "Copying engine…"
/usr/bin/ditto "$SRC_RUNTIME/anylinuxfs/bin"     "$OUT/anylinuxfs/bin"
/usr/bin/ditto "$SRC_RUNTIME/anylinuxfs/lib"     "$OUT/anylinuxfs/lib"
/usr/bin/ditto "$SRC_RUNTIME/anylinuxfs/libexec" "$OUT/anylinuxfs/libexec"
[ -d "$SRC_RUNTIME/anylinuxfs/etc" ] && /usr/bin/ditto "$SRC_RUNTIME/anylinuxfs/etc" "$OUT/anylinuxfs/etc"

echo "Copying Linux root filesystem…"
# The rootfs is shipped as a single archive, not a directory tree: it holds ~500
# symlinks pointing at absolute guest paths, and codesign --verify --strict
# follows them and fails, which would make the signed app unverifiable.
mkdir -p "$OUT/alpine"

# Reduce the guest image to the packages Lukotta can actually reach. The image
# ships everything anylinuxfs supports (LVM, RAID, btrfs, squashfs, ZFS); we
# unlock BitLocker and mount NTFS. Every GPL package shipped is also a package
# whose source must be published with the release, so this shrinks the download
# and the compliance surface together. Set LUKOTTA_NO_TRIM=1 to ship the full image.
STAGE="$(mktemp -d)/rootfs"
/usr/bin/ditto "$SRC_ROOTFS/rootfs" "$STAGE"
if [ "${LUKOTTA_NO_TRIM:-0}" != "1" ]; then
  echo "  trimming guest image…"
  /usr/bin/python3 "$HERE/scripts/trim-image.py" "$STAGE"
fi
# Keep the resulting package database beside the image so the notices describe
# what actually ships rather than what upstream installed.
cp "$STAGE/lib/apk/db/installed" "$OUT/alpine/packages.db"
[ -f "$(dirname "$STAGE")/removed-packages.txt" ] && \
  cp "$(dirname "$STAGE")/removed-packages.txt" "$OUT/alpine/removed-packages.txt"
# Number of entries in the archive, so the first-run unpack can show progress
# rather than a spinner that looks stuck.
/usr/bin/find "$STAGE" | wc -l | tr -d ' ' > "$OUT/alpine/rootfs.count"

echo "  packing rootfs (this takes a moment)…"
/usr/bin/tar --format ustar -czf "$OUT/alpine/rootfs.tar.gz" -C "$(dirname "$STAGE")" rootfs
rm -rf "$(dirname "$STAGE")"
# The engine also reads the OCI image metadata that sits beside the rootfs.
for extra in rootfs.ver config.json umoci.json oci; do
  [ -e "$SRC_ROOTFS/$extra" ] && /usr/bin/ditto "$SRC_ROOTFS/$extra" "$OUT/alpine/$extra"
done
for mtree in "$SRC_ROOTFS"/*.mtree; do
  [ -e "$mtree" ] && cp -f "$mtree" "$OUT/alpine/"
done

# Resolve the external dependency closure and make it bundle-relative. The
# engine links one Homebrew dylib by absolute path; that path will not exist on
# another machine, or once the app is moved.
echo "Relocating dependencies…"
BIN="$OUT/anylinuxfs/bin/anylinuxfs"
/usr/bin/otool -L "$BIN" | tail -n +2 | sed 's/ (compatibility.*//; s/^	//' | \
while IFS= read -r dep; do
  case "$dep" in
    /usr/lib/*|/System/*|@*) continue ;;
  esac
  leaf="${dep##*/}"
  if [ ! -f "$OUT/anylinuxfs/lib/$leaf" ]; then
    [ -f "$dep" ] || { echo "error: missing dependency $dep" >&2; exit 1; }
    cp -f "$dep" "$OUT/anylinuxfs/lib/$leaf"
    /usr/bin/install_name_tool -id "@rpath/$leaf" "$OUT/anylinuxfs/lib/$leaf" 2>/dev/null || true
  fi
  /usr/bin/install_name_tool -change "$dep" "@executable_path/../lib/$leaf" "$BIN"
  echo "  $leaf -> @executable_path/../lib/$leaf"
done

# Verify nothing still points outside the bundle.
remaining="$(/usr/bin/otool -L "$BIN" | tail -n +2 | sed 's/ (compatibility.*//; s/^	//' \
  | grep -vE '^(/usr/lib|/System|@)' || true)"
[ -z "$remaining" ] || { echo "error: unresolved external references: $remaining" >&2; exit 1; }

printf 'Vendored %s (%s)\n' "$OUT" "$(du -sh "$OUT" | awk '{print $1}')"
