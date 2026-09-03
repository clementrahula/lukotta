#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
# Build the two engine binaries Lukotta patches, from pinned source.
#
#   ./scripts/build-engine.sh
#
# Everything else, meaning the libraries, the kernel images and the helpers,
# still comes from the checksummed bottle that scripts/fetch-engine.sh
# downloads. Only these two are built here:
#
#   anylinuxfs   the host binary, patched to offer VMDK, VDI, VHD and VHDX
#   vmproxy      the guest binary, patched to unlock what it probes
#
# The formats are read by two crates the host binary links in, imago and
# krun-devices, which are fetched and patched here as well: imago gains drivers
# for VDI, VHD and VHDX and reads the sparse forms of VMDK, and krun-devices
# selects them by format number. Both are built from their crates.io source,
# checksummed like everything else, and compiled in through [patch.crates-io].
#
# Every patch is in patches/, with what it does and why.
#
# Needs a Rust toolchain and, because vmproxy is a Linux binary and libkrun
# embeds a Linux init, Homebrew's llvm, lld and util-linux:
#
#   brew install llvm lld util-linux
#   rustup target add aarch64-unknown-linux-musl
#
# Skipping this step is allowed and produces a working app without these
# fixes. vendor-engine.sh records which patches were applied, and the app reads
# that record rather than assuming.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$HERE/vendor/engine.lock"
CACHE="${LUKOTTA_ENGINE_CACHE:-$HERE/vendor/.cache}"
OUT="$HERE/vendor/engine-built"
WORK="$CACHE/source"

field() { /usr/bin/python3 -c "import json;d=json.load(open('$LOCK'));print(d['$1']['$2'])"; }
VERSION="$(field anylinuxfs version)"
URL="$(field anylinuxfs source_url)"
WANT="$(field anylinuxfs source_sha256)"

# The crates the host binary links in that carry patches. Their checksums are
# the ones cargo records in anylinuxfs's Cargo.lock, so a mismatch means the
# source is not what upstream resolved.
CRATES=(imago krun-devices)

# Fetch a file and check it against the sha256 in the lock, or stop.
fetch_checked() {
  local url="$1" want="$2" out="$3" what="$4"
  if [ -f "$out" ] && [ "$(/usr/bin/shasum -a 256 "$out" | awk '{print $1}')" = "$want" ]; then
    echo "  cached  $what"
    return
  fi
  echo "  fetch   $what"
  /usr/bin/curl -fsSL --max-time 900 -o "$out" "$url"
  local got
  got="$(/usr/bin/shasum -a 256 "$out" | awk '{print $1}')"
  [ "$got" = "$want" ] || { rm -f "$out"; echo "error: $what checksum mismatch" >&2
    echo "  expected $want" >&2; echo "  got      $got" >&2; exit 1; }
  echo "          sha256 verified"
}

# LUKOTTA_HOST_ONLY=1 builds the host binary and keeps the guest binary that is
# already vendored. vmproxy is a Linux binary and needs a cross-compiler; a
# toolchain without the musl target can still build everything that runs on this
# side, which is where most of the patches are. The guest binary is only kept
# when one is already there to keep -- shipping a host built from patched source
# beside a guest built from something else is exactly the mismatch the patches
# exist to avoid.
HOST_ONLY="${LUKOTTA_HOST_ONLY:-0}"
if [ "$HOST_ONLY" = "1" ] && [ ! -f "$OUT/vmproxy" ]; then
  echo "error: LUKOTTA_HOST_ONLY needs a vmproxy already built in $OUT" >&2
  exit 1
fi

# go builds init-rootfs, which unpacks the Linux image. It used to be taken
# from the bottle, and taking it meant taking one that writes the image into
# ~/.anylinuxfs whatever ANYLINUXFS_HOME says -- the directory every program
# using this engine shares. Built here so the patch that gives this engine a
# directory of its own reaches the program that makes the directory.
for tool in cargo rustc go; do
  command -v "$tool" >/dev/null || {
    echo "error: no $tool. Install a Rust toolchain: https://rustup.rs" >&2; exit 1; }
done
[ -x /opt/homebrew/opt/llvm/bin/clang ] || {
  echo "error: no Homebrew llvm. Run: brew install llvm lld util-linux" >&2; exit 1; }
[ -f /opt/homebrew/opt/util-linux/lib/pkgconfig/blkid.pc ] || {
  echo "error: no Homebrew util-linux. Run: brew install util-linux" >&2; exit 1; }

mkdir -p "$CACHE"
TARBALL="$CACHE/anylinuxfs-src.tar.gz"
if [ -f "$TARBALL" ] && [ "$(/usr/bin/shasum -a 256 "$TARBALL" | awk '{print $1}')" = "$WANT" ]; then
  echo "  cached  anylinuxfs-$VERSION source"
else
  echo "  fetch   anylinuxfs-$VERSION source"
  /usr/bin/curl -fsSL --max-time 900 -o "$TARBALL" "$URL"
  got="$(/usr/bin/shasum -a 256 "$TARBALL" | awk '{print $1}')"
  # As with every other artefact, a mismatch stops the build rather than
  # compiling unexamined source.
  [ "$got" = "$WANT" ] || { rm -f "$TARBALL"; echo "error: source checksum mismatch" >&2
    echo "  expected $WANT" >&2; echo "  got      $got" >&2; exit 1; }
  echo "          sha256 verified"
fi

rm -rf "$WORK"; mkdir -p "$WORK"
/usr/bin/tar -xzf "$TARBALL" -C "$WORK"
SRC="$WORK/anylinuxfs-$VERSION"
[ -d "$SRC" ] || { echo "error: unexpected source layout in $TARBALL" >&2; exit 1; }

# The two crates, beside the source that will link them in.
CRATE_DIR="$WORK/crates"
mkdir -p "$CRATE_DIR"
for crate in "${CRATES[@]}"; do
  cversion="$(field "$crate" version)"
  fetch_checked "$(field "$crate" source_url)" "$(field "$crate" source_sha256)" \
    "$CACHE/$crate.crate" "$crate-$cversion source"
  /usr/bin/tar -xzf "$CACHE/$crate.crate" -C "$CRATE_DIR"
  [ -d "$CRATE_DIR/$crate-$cversion" ] || {
    echo "error: unexpected source layout in $crate.crate" >&2; exit 1; }
done

echo "Applying patches…"
APPLIED=()
for patch in "$HERE"/patches/*.patch; do
  name="$(basename "$patch" .patch)"
  # Each patch says which source it belongs to by what it is named after.
  target="$SRC"
  for crate in "${CRATES[@]}"; do
    case "$name" in
      "$crate"-*) target="$CRATE_DIR/$crate-$(field "$crate" version)" ;;
    esac
  done
  /usr/bin/patch -p1 -d "$target" -s < "$patch"
  echo "  $name"
  APPLIED+=("$name")
done

# Build against the patched crates rather than the published ones. Cargo still
# resolves versions from the lock and only the source location changes, so the
# versions here must be the ones already resolved.
# The manifest already has a [patch.crates-io] section, and a second one is an
# error, so these go into the one that is there.
{
  for crate in "${CRATES[@]}"; do
    printf '%s = { path = "%s" }\n' \
      "$crate" "$CRATE_DIR/$crate-$(field "$crate" version)"
  done
} > "$WORK/patches.toml"
/usr/bin/python3 - "$SRC/anylinuxfs/Cargo.toml" "$WORK/patches.toml" <<'PYEOF'
import sys
manifest, additions = sys.argv[1], sys.argv[2]
text = open(manifest).read()
head, marker, tail = text.partition("[patch.crates-io]\n")
if not marker:
    raise SystemExit("error: no [patch.crates-io] in " + manifest)
open(manifest, "w").write(head + marker + open(additions).read() + tail)
PYEOF

echo "Building…"
export PATH="/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/llvm/bin:$PATH"

# Nothing of the machine that built this goes into a binary somebody else runs.
#
# rustc writes absolute source paths into panic messages and debug info, so a
# plain build bakes in wherever the crates happened to sit: the work tree and
# the registry, both inside a home directory. Nobody looks at a vendored binary
# for that and check-private.py cannot -- it reads what git tracks, and vendor/
# is ignored -- so it travelled to everyone who installed the app.
#
# Appended to each crate's own rustflags rather than exported as RUSTFLAGS or
# asked for as a profile. The environment variable REPLACES target.*.rustflags
# instead of adding to them, and vmproxy keeps its cross-linker there: set that
# way, -Clink-arg=-fuse-ld=lld disappears, clang falls back to the host ld, and
# the guest binary fails to link on options only GNU ld understands. The
# profile key trim-paths does the job properly and is not stabilised in the
# pinned cargo. Appending to what is already written also means upstream
# changing its linker flags cannot silently drop ours.
#
# One mapping, not several: CARGO_HOME and the work tree both sit under the
# home directory, so remapping it covers them with no question about which of
# two overlapping rules wins.
/usr/bin/python3 "$HERE/scripts/remap-build-paths.py" "$SRC" "$HOME"

( cd "$SRC/anylinuxfs" && cargo build --release --quiet )
HOST="$SRC/anylinuxfs/target/release/anylinuxfs"
[ -x "$HOST" ] || { echo "error: no anylinuxfs was built" >&2; exit 1; }

GUEST="$SRC/vmproxy/target/aarch64-unknown-linux-musl/release/vmproxy"
if [ "$HOST_ONLY" = "1" ]; then
  KEPT="$(mktemp -d)/vmproxy"
  cp "$OUT/vmproxy" "$KEPT"
  GUEST="$KEPT"
  echo "  keeping the vmproxy already built"
else
  ( cd "$SRC/vmproxy" && cargo build --release --quiet )
  [ -f "$GUEST" ] || { echo "error: no vmproxy was built" >&2; exit 1; }
fi

# The image unpacker, patched to keep to the directory it is given.
# With cgo, which it needs: vmrunner beside it is a cgo package with a header,
# and CGO_ENABLED=0 excludes every file in it -- "build constraints exclude all
# Go files", which reads like a platform problem and is not one.
# The static library the unpacker links. It is a Rust crate built as a
# staticlib, and the Go build asks clang for it by a path relative to itself, so
# it has to exist before the Go build and cannot be built by it.
( cd "$SRC/vmrunner-sys" && cargo build --release --quiet )
VMRUNNER_LIB="$SRC/vmrunner-sys/target/release/libvmrunner_sys.a"
[ -f "$VMRUNNER_LIB" ] || { echo "error: no libvmrunner_sys.a was built" >&2; exit 1; }
mkdir -p "$SRC/vmrunner-sys/target"
cp "$VMRUNNER_LIB" "$SRC/vmrunner-sys/target/libvmrunner_sys.a"

# The tag is upstream's own, from its build notes. Without it the OCI library
# wants gpgme through pkg-config, which is a C library to install, to ship and
# to license, for signature verification this does not do.
( cd "$SRC/init-rootfs" \
    && go build -trimpath -ldflags="-w -s" -tags containers_image_openpgp \
        -o "$SRC/init-rootfs/init-rootfs" . )
UNPACKER="$SRC/init-rootfs/init-rootfs"
[ -x "$UNPACKER" ] || { echo "error: no init-rootfs was built" >&2; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"
cp "$HOST" "$GUEST" "$UNPACKER" "$OUT/"

# Checked rather than intended. A remap that stops working -- a flag rustc
# renames, a RUSTFLAGS somewhere downstream that replaces this one rather than
# adding to it, a crate built before the export -- is silent, and the next
# person to notice is whoever runs `strings` on a release. Fail the build
# instead. The home directory is the thing that must not be there; the account
# name is asked of the system, never written down here.
for __b in "$OUT/anylinuxfs" "$OUT/vmproxy"; do
  # Counted, not matched. `grep -q` exits the moment it finds the path, the
  # `strings` feeding it dies of SIGPIPE, and `set -o pipefail` reports that
  # death as the pipeline's status -- so the guard went quiet in exactly the
  # case it exists for, and a binary carrying the builder's home directory
  # would have shipped. Demonstrated on a file that did carry one: matched,
  # silent; counted, caught.
  if [ "$(LC_ALL=C strings "$__b" 2>/dev/null | grep -cF "$HOME")" -gt 0 ]; then
    echo "error: $__b carries the path of the machine that built it." >&2
    echo "       RUSTFLAGS did not reach the compiler; nothing is shipped." >&2
    exit 1
  fi
done

# The host binary needs the same entitlements upstream signs it with, or
# Hypervisor.framework refuses it.
/usr/bin/codesign --force -s - --entitlements "$SRC/anylinuxfs.entitlements" \
  "$OUT/anylinuxfs" 2>/dev/null
printf '%s\n' "${APPLIED[@]}" > "$OUT/PATCHES"

printf 'Built into %s\n' "$OUT"
sed 's/^/  /' "$OUT/PATCHES"
