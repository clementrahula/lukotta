#!/bin/bash
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
