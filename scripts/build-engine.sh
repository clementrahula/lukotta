#!/bin/bash
# Build the two engine binaries Lukotta patches, from pinned source.
#
#   ./scripts/build-engine.sh
#
# Everything else — libraries, the kernel images, the helpers — still comes from
# the checksummed bottle that scripts/fetch-engine.sh downloads. Only these two
# are ours:
#
#   anylinuxfs   the host binary, patched to offer VMDK
#   vmproxy      the guest binary, patched to unlock what it probes
#
# Both patches are in patches/, with what they do and why.
#
# Needs a Rust toolchain and, because vmproxy is a Linux binary and libkrun
# embeds a Linux init, Homebrew's llvm, lld and util-linux:
#
#   brew install llvm lld util-linux
#   rustup target add aarch64-unknown-linux-musl
#
# Skipping this is allowed and produces a working app — one without the two
# fixes. `vendor-engine.sh` records which patches made it in, and the app reads
# that rather than assuming.
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

for tool in cargo rustc; do
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
  # The same rule as every other artefact: a mismatch stops the build rather
  # than compiling something unexamined.
  [ "$got" = "$WANT" ] || { rm -f "$TARBALL"; echo "error: source checksum mismatch" >&2
    echo "  expected $WANT" >&2; echo "  got      $got" >&2; exit 1; }
  echo "          sha256 verified"
fi

rm -rf "$WORK"; mkdir -p "$WORK"
/usr/bin/tar -xzf "$TARBALL" -C "$WORK"
SRC="$WORK/anylinuxfs-$VERSION"
[ -d "$SRC" ] || { echo "error: unexpected source layout in $TARBALL" >&2; exit 1; }

echo "Applying patches…"
APPLIED=()
for patch in "$HERE"/patches/*.patch; do
  name="$(basename "$patch" .patch)"
  /usr/bin/patch -p1 -d "$SRC" -s < "$patch"
  echo "  $name"
  APPLIED+=("$name")
done

echo "Building…"
export PATH="/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/llvm/bin:$PATH"
( cd "$SRC/anylinuxfs" && cargo build --release --quiet )
( cd "$SRC/vmproxy"    && cargo build --release --quiet )

HOST="$SRC/anylinuxfs/target/release/anylinuxfs"
GUEST="$SRC/vmproxy/target/aarch64-unknown-linux-musl/release/vmproxy"
[ -x "$HOST" ]  || { echo "error: no anylinuxfs was built" >&2; exit 1; }
[ -f "$GUEST" ] || { echo "error: no vmproxy was built" >&2; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"
cp "$HOST" "$GUEST" "$OUT/"
# The host binary needs the same entitlements upstream signs it with, or
# Hypervisor.framework refuses it.
/usr/bin/codesign --force -s - --entitlements "$SRC/anylinuxfs.entitlements" \
  "$OUT/anylinuxfs" 2>/dev/null
printf '%s\n' "${APPLIED[@]}" > "$OUT/PATCHES"

printf 'Built into %s\n' "$OUT"
sed 's/^/  /' "$OUT/PATCHES"
