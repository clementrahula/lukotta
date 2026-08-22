#!/bin/bash
# Vendor the anylinuxfs runtime into ./vendor/engine so the app can ship it.
#
# The app must not download anything on first run, so every host-side component
# is copied in and made position-independent. Only the pieces actually reachable
# at runtime are taken: the full Homebrew dependency trees are ~60 MB of
# binaries the engine never invokes on the host.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# Staged from artefacts fetched and checksummed against vendor/engine.lock, not
# from whatever happens to be installed here. Staging from a local install is
# what made the build unreproducible and what quietly set the app's minimum
# macOS to that of the build machine.
UPSTREAM="$HERE/vendor/upstream"
LOCK="$HERE/vendor/engine.lock"
lockfield() { /usr/bin/python3 -c "import json;d=json.load(open('$LOCK'));print(d['$1']['$2'])"; }
ALFS_VERSION="$(lockfield anylinuxfs version)"
UTIL_VERSION="$(lockfield util_linux version)"

[ -x "$UPSTREAM/anylinuxfs/$ALFS_VERSION/bin/anylinuxfs" ] || "$HERE/scripts/fetch-engine.sh"

SRC_RUNTIME="${LUKOTTA_SRC_RUNTIME:-$UPSTREAM}"
SRC_BLKID="$UPSTREAM/util-linux/$UTIL_VERSION/lib"
# Still from a local install: the guest image is downloaded by "anylinuxfs init"
# rather than shipped in the bottle. Its identity is recorded in the lock.
SRC_ROOTFS="${LUKOTTA_SRC_ROOTFS:-$HOME/.anylinuxfs/alpine}"
OUT="$HERE/vendor/engine"

[ -x "$SRC_RUNTIME/anylinuxfs/$ALFS_VERSION/bin/anylinuxfs" ] || {
  echo "error: no anylinuxfs $ALFS_VERSION under $SRC_RUNTIME" >&2; exit 1; }
[ -d "$SRC_ROOTFS/rootfs" ] || {
  echo "error: no Linux rootfs at $SRC_ROOTFS/rootfs" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/anylinuxfs/lib"

echo "Copying engine…"
ALFS="$SRC_RUNTIME/anylinuxfs/$ALFS_VERSION"
/usr/bin/ditto "$ALFS/bin"     "$OUT/anylinuxfs/bin"
/usr/bin/ditto "$ALFS/lib"     "$OUT/anylinuxfs/lib"
/usr/bin/ditto "$ALFS/libexec" "$OUT/anylinuxfs/libexec"
[ -d "$ALFS/etc" ] && /usr/bin/ditto "$ALFS/etc" "$OUT/anylinuxfs/etc"
[ -d "$ALFS/share" ] && /usr/bin/ditto "$ALFS/share" "$OUT/anylinuxfs/share"
# Our own build of the two binaries we patch, when there is one.
#
# Everything else stays as the bottle shipped it. Only these two carry changes,
# and which changes is written down beside them so the app can read it rather
# than assume: an app built without running scripts/build-engine.sh works, it
# simply does not have the fixes.
BUILT="$HERE/vendor/engine-built"
if [ -x "$BUILT/anylinuxfs" ] && [ -f "$BUILT/vmproxy" ]; then
  echo "  using our own build of anylinuxfs and vmproxy"
  cp -f "$BUILT/anylinuxfs" "$OUT/anylinuxfs/bin/anylinuxfs"
  cp -f "$BUILT/vmproxy"    "$OUT/anylinuxfs/libexec/vmproxy"
  cp -f "$BUILT/PATCHES"    "$OUT/anylinuxfs/PATCHES"
  sed 's/^/    /' "$BUILT/PATCHES"
else
  echo "  upstream anylinuxfs and vmproxy, unpatched"
  echo "  (run scripts/build-engine.sh for the qcow2 and VMDK fixes)"
  rm -f "$OUT/anylinuxfs/PATCHES"
fi

# The one library the engine links from outside its own bottle. It sets the
# lowest macOS the finished app supports, so it is pinned like everything else.
cp -f "$SRC_BLKID/libblkid.1.dylib" "$OUT/anylinuxfs/lib/libblkid.1.dylib"
/usr/bin/install_name_tool -id "@rpath/libblkid.1.dylib" "$OUT/anylinuxfs/lib/libblkid.1.dylib" 2>/dev/null || true

# The image is downloaded by "anylinuxfs init" rather than shipped in the
# bottle, so it is the one piece not fetched here. Its identity is checked
# instead: umoci leaves the manifest digest in the name of the mtree file beside
# it, and the lock records which digest this release was built against.
WANT_DIGEST="$(lockfield guest_image oci_digest | sed 's/^sha256://')"
if [ -n "$WANT_DIGEST" ]; then
  if [ -e "$SRC_ROOTFS/sha256_$WANT_DIGEST.mtree" ]; then
    echo "  guest image digest matches the lock"
  else
    echo "error: the guest image is not the one vendor/engine.lock pins." >&2
    echo "  expected sha256:$WANT_DIGEST" >&2
    /usr/bin/find "$SRC_ROOTFS" -maxdepth 1 -name '*.mtree' -exec basename {} \; 2>/dev/null \
      | sed 's/^/  found:   /' >&2
    echo "  Re-create it with: $UPSTREAM/anylinuxfs/$ALFS_VERSION/bin/anylinuxfs init" >&2
    exit 1
  fi
fi

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
    # @@HOMEBREW_PREFIX@@ is a placeholder a bottle carries until Homebrew
    # rewrites it. Skipping everything beginning with @ skipped that too, and
    # left the finished binary pointing at a path that exists nowhere.
    @@HOMEBREW_PREFIX@@*) ;;
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
