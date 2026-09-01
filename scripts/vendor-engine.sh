#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
# Vendor the anylinuxfs runtime into ./vendor/engine so the app can ship it.
#
# The app must not download anything on first run, so every host-side component
# is copied in and made position-independent. Only the pieces actually reachable
# at runtime are taken: the full Homebrew dependency trees are ~60 MB of
# binaries the engine never invokes on the host.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# Staged from artefacts fetched and checksummed against vendor/engine.lock
# rather than from whatever is installed on this machine. Staging from a local
# install made the build unreproducible and set the app's minimum macOS to that
# of the build machine.
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
#
# What that image carries decides what the app can repair, and today it carries
# creation and repair tools for btrfs, vfat and ntfs only. There is no e2fsck
# and no xfs_repair, so ext and XFS depend entirely on the kernel replaying
# their journals when it mounts them, and have no answer to damage past that --
# while NTFS has ntfsfix and is the only format the app can actually mend. The
# keep-list in trim-image.py names e2fsprogs among the filesystems found inside
# LUKS containers, but a keep-list only keeps what is there and nothing put it
# there.
#
# Closing that is a step before this script rather than a change inside it,
# because the packages belong in the image being vendored:
#
#     anylinuxfs apk add e2fsprogs xfsprogs   # no machine may be running
#     LUKOTTA_REPACK_GUEST=1 ./scripts/vendor-engine.sh
#
# Measure the archive afterwards. The guest is trimmed on purpose -- 67
# packages, and trim-image.py exists to keep it that way -- so this is a size
# decision as much as a capability one, and it is not taken by accident.
#
# Two places to look. The app keeps its own copy inside its Application Support
# directory now, so that nothing on the Mac shares an image with it; a plain
# "anylinuxfs init" still writes to the shared one. Either is a valid source --
# the archive is checked against the digest the lock pins whichever it came
# from.
SRC_ROOTFS="${LUKOTTA_SRC_ROOTFS:-}"
if [ -z "$SRC_ROOTFS" ]; then
  for candidate in \
    "$HOME/Library/Application Support/Lukotta/engine/.anylinuxfs/alpine" \
    "$HOME/Library/Application Support/Lukotta Beta/engine/.anylinuxfs/alpine" \
    "$HOME/.anylinuxfs/alpine"; do
    [ -d "$candidate/rootfs" ] || continue
    SRC_ROOTFS="$candidate"
    break
  done
  SRC_ROOTFS="${SRC_ROOTFS:-$HOME/.anylinuxfs/alpine}"
fi
OUT="$HERE/vendor/engine"

[ -x "$SRC_RUNTIME/anylinuxfs/$ALFS_VERSION/bin/anylinuxfs" ] || {
  echo "error: no anylinuxfs $ALFS_VERSION under $SRC_RUNTIME" >&2; exit 1; }
[ -d "$SRC_ROOTFS/rootfs" ] || {
  echo "error: no Linux rootfs at $SRC_ROOTFS/rootfs" >&2; exit 1; }

# The guest already vendored, set aside before the wipe that follows.
#
# Packing one means trimming a copy of the untrimmed image, and the only
# sources on a Mac that has built this before are trimmed copies of the packed
# one -- the application's own directory and the engine's, both filled from a
# build. Trimming one of those leaves an image with nothing in it. The boot
# check catches it, but only after the vendored guest has been overwritten, so
# a second run of this script destroyed what the first produced and no run
# afterwards could rebuild it.
#
# So it is kept, and this run refreshes the binaries around it. That is what a
# host-side patch wants in any case: nothing about the guest changed.
KEPT_GUEST=""
if [ -f "$OUT/alpine/rootfs.tar.gz" ] && [ "${LUKOTTA_REPACK_GUEST:-0}" != "1" ]; then
  KEPT_GUEST="$(mktemp -d)/alpine"
  /usr/bin/ditto "$OUT/alpine" "$KEPT_GUEST"
fi

rm -rf "$OUT"
mkdir -p "$OUT/anylinuxfs/lib"

echo "Copying engine…"
ALFS="$SRC_RUNTIME/anylinuxfs/$ALFS_VERSION"
/usr/bin/ditto "$ALFS/bin"     "$OUT/anylinuxfs/bin"
/usr/bin/ditto "$ALFS/lib"     "$OUT/anylinuxfs/lib"
/usr/bin/ditto "$ALFS/libexec" "$OUT/anylinuxfs/libexec"
[ -d "$ALFS/etc" ] && /usr/bin/ditto "$ALFS/etc" "$OUT/anylinuxfs/etc"
[ -d "$ALFS/share" ] && /usr/bin/ditto "$ALFS/share" "$OUT/anylinuxfs/share"
# The locally built copies of the two patched binaries, when they exist.
#
# Everything else stays as the bottle shipped it. Only these two carry changes,
# and the patch names are recorded beside them for the app to read rather than
# assume. An app built without running scripts/build-engine.sh works and does
# not have the fixes.
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

if [ -n "$KEPT_GUEST" ]; then
  mkdir -p "$OUT/alpine"
  /usr/bin/ditto "$KEPT_GUEST" "$OUT/alpine"
  rm -rf "$(dirname "$KEPT_GUEST")"
  echo "Keeping the Linux root filesystem already vendored ($(du -h "$OUT/alpine/rootfs.tar.gz" | awk '{print $1}'))"
  echo "  LUKOTTA_REPACK_GUEST=1 packs a new one, from an image nothing has trimmed"
else

echo "Copying Linux root filesystem…"
# The rootfs is shipped as a single archive rather than a directory tree. It
# holds about 500 symlinks pointing at absolute guest paths, which
# codesign --verify --strict follows and fails on, leaving the signed app
# unverifiable.
mkdir -p "$OUT/alpine"

# Reduce the guest image to the packages Lukotta reaches. The image ships
# everything anylinuxfs supports, including LVM, RAID, btrfs, squashfs and ZFS.
# Source for every GPL package shipped must be published with the release, so
# trimming reduces the download and the compliance surface together. Set
# LUKOTTA_NO_TRIM=1 to ship the full image.
STAGE="$(mktemp -d)/rootfs"
/usr/bin/ditto "$SRC_ROOTFS/rootfs" "$STAGE"

# Put the guest's own permissions back on the files.
#
# Most of this image is not unpacked from the OCI layer: "anylinuxfs init" boots
# the machine and installs the packages inside it, so those files are written
# back out through virtiofs. What macOS then stores is mode 0600 with the real
# mode kept beside it in an extended attribute -- uid:gid:mode -- which the
# engine reads and hands to the guest. The archive carries no extended
# attributes, so without this every binary in the image arrives unexecutable and
# the guest boots far enough to answer every question with nothing.
/usr/bin/python3 - "$STAGE" <<'PY'
import ctypes, ctypes.util, os, sys

# getxattr(2) itself: macOS has no os.getxattr, and the xattr module is not in
# the system Python.
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
libc.getxattr.argtypes = [
    ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
    ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int,
]
libc.getxattr.restype = ctypes.c_ssize_t
XATTR_NOFOLLOW = 0x0001

def recorded_mode(path):
    # Asked for its length first: a value longer than the buffer fails with
    # ERANGE, which from here looks exactly like "there is no such attribute"
    # and leaves the file unexecutable in the image that ships.
    needed = libc.getxattr(
        path.encode(), b"user.containers.override_stat", None, 0, 0, XATTR_NOFOLLOW)
    if needed <= 0:
        return None
    buf = ctypes.create_string_buffer(needed)
    size = libc.getxattr(
        path.encode(), b"user.containers.override_stat", buf, len(buf), 0, XATTR_NOFOLLOW)
    if size <= 0:
        return None
    # uid:gid:mode, the mode in octal with the file type in it.
    parts = buf.raw[:size].decode(errors="replace").split(":")
    if len(parts) < 3:
        return None
    try:
        return int(parts[2], 8) & 0o7777
    except ValueError:
        return None

root = sys.argv[1]
fixed = 0
for base, dirs, files in os.walk(root):
    for name in dirs + files:
        path = os.path.join(base, name)
        if os.path.islink(path):
            continue
        mode = recorded_mode(path)
        if mode and mode != (os.stat(path).st_mode & 0o7777):
            os.chmod(path, mode)
            fixed += 1
print(f"  restored guest permissions on {fixed} files")
PY
if [ "${LUKOTTA_NO_TRIM:-0}" != "1" ]; then
  echo "  trimming guest image…"
  /usr/bin/python3 "$HERE/scripts/trim-image.py" "$STAGE"
fi
# Keep the resulting package database beside the image so that the notices
# describe what ships rather than what upstream installed.
cp "$STAGE/lib/apk/db/installed" "$OUT/alpine/packages.db"
[ -f "$(dirname "$STAGE")/removed-packages.txt" ] && \
  cp "$(dirname "$STAGE")/removed-packages.txt" "$OUT/alpine/removed-packages.txt"

# The same database again, as an SBOM, and this one is committed. The audit
# workflow runs on a Linux runner with nothing but a checkout: it cannot see
# this vendor tree, so anything it is to scan has to be in the repository.
# Written from the trimmed image, so it lists what ships and not what upstream
# installed.
/usr/bin/python3 "$HERE/scripts/guest-sbom.py" \
  "$OUT/alpine/packages.db" "$HERE/vendor/guest-sbom.json"
# Number of entries in the archive, so that the first-run unpack shows progress
# rather than a spinner.
/usr/bin/find "$STAGE" | wc -l | tr -d ' ' > "$OUT/alpine/rootfs.count"

echo "  packing rootfs (this takes a moment)…"
# pax rather than ustar: the guest's real owner and mode are kept in an extended
# attribute beside each file, which ustar cannot carry and pax can. Without them
# the engine hands the guest a filesystem owned by whoever installed the app,
# and nothing that needs root inside the machine will run.
/usr/bin/tar --format pax -czf "$OUT/alpine/rootfs.tar.gz" -C "$(dirname "$STAGE")" rootfs
rm -rf "$(dirname "$STAGE")"

# Prove the archive still describes a working machine. Everything above is
# silent when it goes wrong: an archive format that drops the attribute, a
# source image assembled by something other than "anylinuxfs init", a trim that
# takes a directory the kernel needs. All three shipped at once, and the app
# unpacked none of it until now, so nothing said a word.
CHECK="$(mktemp -d)"
/usr/bin/tar -xzpf "$OUT/alpine/rootfs.tar.gz" -C "$CHECK" 2>/dev/null
fault=""
for d in proc sys dev tmp run; do
  [ -d "$CHECK/rootfs/$d" ] || fault="$fault /$d"
done

# Every tool an unlock actually goes through, not only the one that lists disks.
# lsblk running proves the machine boots and can answer a question; it says
# nothing about whether an encrypted volume can be opened, an NTFS volume
# mounted, or the export served. Each arrives unexecutable if its recorded mode
# was missing or unreadable, and each then fails somewhere else entirely.
for tool in bin/lsblk sbin/cryptsetup bin/mount sbin/blkid bin/busybox \
            sbin/mount.ntfs-3g sbin/rpc.nfsd sbin/exportfs sbin/rpc.mountd; do
  [ -e "$CHECK/rootfs/$tool" ] || continue   # not every image carries every one
  [ -x "$CHECK/rootfs/$tool" ] || fault="$fault $tool-not-executable"
done
# And the two without which nothing works at all have to be there.
[ -x "$CHECK/rootfs/bin/lsblk" ] || fault="$fault bin/lsblk-missing"
[ -x "$CHECK/rootfs/sbin/cryptsetup" ] || fault="$fault sbin/cryptsetup-missing"
# Nothing left unexecutable anywhere among the tools: one file whose recorded
# mode could not be read is one command that fails when somebody needs it.
UNEXECUTABLE="$(/usr/bin/find "$CHECK/rootfs/bin" "$CHECK/rootfs/sbin" \
  "$CHECK/rootfs/usr/bin" "$CHECK/rootfs/usr/sbin" \
  -type f ! -perm -u+x 2>/dev/null | wc -l | tr -d ' ')"
[ "$UNEXECUTABLE" = "0" ] || fault="$fault $UNEXECUTABLE-unexecutable-tools"
/usr/bin/xattr -p user.containers.override_stat "$CHECK/rootfs/bin/lsblk" >/dev/null 2>&1   || fault="$fault bin/lsblk-has-no-guest-owner"
rm -rf "$CHECK"
if [ -n "$fault" ]; then
  echo "error: the packed guest would not boot -- missing:$fault" >&2
  exit 1
fi
echo "  the packed guest keeps its mount points, its permissions and its owner"
# The engine also reads the OCI image metadata that sits beside the rootfs.
for extra in rootfs.ver config.json umoci.json oci; do
  [ -e "$SRC_ROOTFS/$extra" ] && /usr/bin/ditto "$SRC_ROOTFS/$extra" "$OUT/alpine/$extra"
done
for mtree in "$SRC_ROOTFS"/*.mtree; do
  [ -e "$mtree" ] && cp -f "$mtree" "$OUT/alpine/"
done

fi  # the guest was packed rather than kept

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
