#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Builds the engine's guest kernel, libexec/Image, as it ships plus this
# project's patches/linux-*.patch, and writes it with its sha256 beside it.
#
#   ./scripts/build-guest-kernel.sh <where to write the Image>
#
# Docker is the build environment and nothing else needs it.
set -euo pipefail

# Everything temporary this run makes goes in one directory this project owns,
# so that killing the run leaves nothing loose in $TMPDIR to be guessed at later.
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ $# -eq 1 ] || { echo "usage: $0 <where to write the Image>" >&2; exit 64; }
DEST="$1"

# The kernel anylinuxfs 0.19.0 ships comes from this fork's release, not from
# libkrunfw itself.
FORK_REPO="https://github.com/nohajc/libkrunfw"
FORK_TAG="v6.12.62-rev1"
FORK_COMMIT="9fe60c621c3dce85680274262c1be90046dbd6fc"
KERNEL="linux-6.12.62"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/$KERNEL.tar.xz"
KERNEL_SHA256="13e2c685ac8fab5dd992dd105732554dae514aef350c2a8c7418e7b74eb62c13"
# The version the shipped modules.squashfs reports. Only its Kconfig symbol
# reaches the Image, ZFS being a module.
ZFS="zfs-2.4.0"
ZFS_URL="https://github.com/openzfs/zfs/releases/download/$ZFS/$ZFS.tar.gz"
ZFS_SHA256="7bdf13de0a71d95554c0e3e47d5e8f50786c30d4f4b63b7c593b1d11af75c9ee"
CONFIG="$HERE/patches/$KERNEL-guest.config"
# This project's, applied after the fork's in this order. Named rather than
# globbed, so a patch still being written beside them is not built in unasked.
OWN_PATCHES=(linux-nfsd-commit-is-durable.patch linux-ntfs3-readdir-survives-deletion.patch)
# Bookworm, because the config records its gcc 12.2 and binutils 2.40.
BUILDER="debian:bookworm@sha256:6ebd97fa83deb272194a2cf015b3d26a4d538e9ad3a7a79d544c8af5b0a01443"
# libexec/Image in the anylinuxfs 0.19.0 bottle.
SHIPPED_SHA256="1c4a26f2f07156b2d50018a97843065e217475947867f54da4e08362389f834e"

# AS_SHIPPED leaves this project's patches out and names the build as the
# fork's Makefile does, to check the recipe against the Image that ships. The
# name is in /proc/version and is no config symbol. The one difference left is
# the embedded headers archive: the fork's came from an earlier config, on a
# filesystem that folds case.
if [ "${LUKOTTA_KERNEL_AS_SHIPPED:-0}" = "1" ]; then
  AS_SHIPPED=1
  BUILD_HOST="libkrunfw"
  BUILD_TIMESTAMP="Mon Dec 15 19:43:20 CET 2025"
else
  AS_SHIPPED=0
  BUILD_HOST="lukotta"
  BUILD_TIMESTAMP="Thu Sep 10 00:00:00 UTC 2026"
fi

CACHE="${LUKOTTA_ENGINE_CACHE:-$HERE/vendor/.cache}"

for tool in docker git curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: no $tool" >&2; exit 2; }
done
docker version >/dev/null 2>&1 || {
  echo "error: docker is installed but its daemon is not running" >&2; exit 2; }
[ -f "$CONFIG" ] || { echo "error: no $CONFIG" >&2; exit 1; }

# Fetch a file and check it against its pinned sha256, or stop.
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

mkdir -p "$CACHE"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Inputs…"
fetch_checked "$KERNEL_URL" "$KERNEL_SHA256" "$CACHE/$KERNEL.tar.xz" "$KERNEL"
fetch_checked "$ZFS_URL" "$ZFS_SHA256" "$CACHE/$ZFS.tar.gz" "$ZFS"

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$FORK_TAG" \
  "$FORK_REPO" "$WORK/fork"
got="$(git -C "$WORK/fork" rev-parse HEAD)"
[ "$got" = "$FORK_COMMIT" ] || {
  echo "error: $FORK_TAG is now $got, not the pinned $FORK_COMMIT" >&2; exit 1; }
echo "  nohajc/libkrunfw $FORK_TAG at $FORK_COMMIT"
[ "$(grep -c "^KERNEL_VERSION = $KERNEL\$" "$WORK/fork/Makefile" || true)" = "1" ] || {
  echo "error: the fork's Makefile does not build $KERNEL" >&2; exit 1; }
if cmp -s "$WORK/fork/config-libkrunfw_aarch64" "$CONFIG"; then
  echo "  the config is the fork's config-libkrunfw_aarch64, unchanged"
else
  echo "  the config differs from the fork's config-libkrunfw_aarch64"
fi

mkdir -p "$WORK/own" "$WORK/out"
if [ "$AS_SHIPPED" = "0" ]; then
  i=0
  for name in "${OWN_PATCHES[@]}"; do
    i=$((i + 1))
    cp "$HERE/patches/$name" "$WORK/own/$(printf '%02d' "$i")-$name"
  done
fi
for patch in "$HERE"/patches/linux-*.patch; do
  [ -e "$patch" ] || continue
  case " ${OWN_PATCHES[*]} " in
    *" ${patch##*/} "*) ;;
    *) echo "  not in this build: patches/${patch##*/}" ;;
  esac
done

cat > "$WORK/build.sh" <<'INNER'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
log=/out/build.log
say() { printf '  %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

echo "Toolchain…"
{ apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    build-essential bc bison flex libssl-dev libelf-dev cpio python3 xz-utils \
    dwarves; } >"$log" 2>&1 || { tail -20 "$log"; fail "could not install the toolchain"; }
v="$(gcc --version)"; say "${v%%$'\n'*}"
v="$(ld --version)"; say "${v%%$'\n'*}"
v="$(pahole --version)"; say "pahole $v"

echo "Source…"
mkdir -p /build && cd /build
tar -xJf /in/kernel.tar.xz
K="/build/$KERNEL"
n=0
while IFS= read -r p; do
  patch -p1 -s -d "$K" < "$p"
  n=$((n + 1))
done < <(find /in/fork-patches -name '0*.patch' | LC_ALL=C sort)
say "the fork's $n patches"
for p in /in/own-patches/*.patch; do
  [ -e "$p" ] || continue
  patch -p1 -s --fuzz=0 -d "$K" < "$p"
  say "${p##*/}"
done

# ZFS's configure compiles its checks against the tree, so the tree is
# configured and prepared first, and only its kernel half is configured.
cp /in/config "$K/.config"
{ make -C "$K" -s olddefconfig && make -C "$K" -s -j"$(nproc)" modules_prepare; } \
  >>"$log" 2>&1 || { tail -30 "$log"; fail "could not prepare the tree"; }
tar -xzf /in/zfs.tar.gz -C /build
( cd "/build/$ZFS" \
  && ./configure --with-config=kernel --enable-linux-builtin \
       --with-linux="$K" --with-linux-obj="$K" \
  && ./copy-builtin "$K" ) >>"$log" 2>&1 || { tail -30 "$log"; fail "could not graft $ZFS"; }
say "$ZFS grafted in"

echo "Config…"
cp /in/config "$K/.config"
make -C "$K" -s olddefconfig >>"$log" 2>&1
if cmp -s "$K/.config" /in/config; then
  say "olddefconfig changed nothing"
else
  echo "error: olddefconfig changed the config:" >&2
  diff /in/config "$K/.config" | grep '^[<>]' >&2 || true
  exit 1
fi

echo "Building Image with $(nproc) jobs…"
t0=$(date +%s)
make -C "$K" -s -j"$(nproc)" \
  KBUILD_BUILD_TIMESTAMP="$BUILD_TIMESTAMP" KBUILD_BUILD_USER=root \
  KBUILD_BUILD_HOST="$BUILD_HOST" Image >>"$log" 2>&1 \
  || { tail -40 "$log"; fail "the kernel did not build"; }
say "built in $(( $(date +%s) - t0 )) s"
grep 'warning:' "$log" | sed 's/^/  /' || true

echo "Checks…"
"$K/scripts/extract-ikconfig" "$K/arch/arm64/boot/Image" > /out/embedded.config \
  || fail "no config embedded in the Image"
if cmp -s /out/embedded.config /in/config; then
  say "the config embedded in the Image is the pinned one, byte for byte"
else
  diff /in/config /out/embedded.config | grep '^[<>]' >&2 || true
  fail "the config embedded in the Image is not the pinned one"
fi

# Each patch shows as a call in a function it changes. A disassembly that never
# found the function is not one without the call.
calls_in() {
  objdump -d --no-show-raw-insn --disassemble="$1" "$K/vmlinux" > "/out/$1.dis"
  [ "$(grep -c "<$1>:\$" "/out/$1.dis" || true)" = "1" ] || fail "$1 is not in vmlinux to be read"
  grep -cE "<($2)(\\.[a-z]+\\.[0-9]+)?>\$" "/out/$1.dis" || true
}
for check in "nfsd_commit nfsd_sync_fs|sync_filesystem" \
             "nfsd_rename nfsd_sync_fs|sync_filesystem" \
             "ni_remove_name ntfs_dir_forget"; do
  set -- $check
  n="$(calls_in "$1" "$2")"
  say "$1 calls $2: $n"
  if [ "$EXPECT_SYNC" = "1" ]; then
    [ "$n" -ge 1 ] || fail "$1 does not call $2: the patch is not in"
  else
    [ "$n" = "0" ] || fail "$1 calls $2 in a build meant to be as shipped"
  fi
done

cp "$K/arch/arm64/boot/Image" /out/Image
INNER

echo "Building in $BUILDER…"
t0=$(date +%s)
docker run --rm --platform linux/arm64 \
  -e KERNEL="$KERNEL" -e ZFS="$ZFS" \
  -e BUILD_HOST="$BUILD_HOST" -e BUILD_TIMESTAMP="$BUILD_TIMESTAMP" \
  -e EXPECT_SYNC="$((1 - AS_SHIPPED))" \
  -v "$CACHE/$KERNEL.tar.xz:/in/kernel.tar.xz:ro" \
  -v "$CACHE/$ZFS.tar.gz:/in/zfs.tar.gz:ro" \
  -v "$WORK/fork/patches:/in/fork-patches:ro" \
  -v "$WORK/own:/in/own-patches:ro" \
  -v "$CONFIG:/in/config:ro" \
  -v "$WORK/build.sh:/in/build.sh:ro" \
  -v "$WORK/out:/out" \
  "$BUILDER" bash /in/build.sh
echo "  $(( $(date +%s) - t0 )) s in the container, toolchain included"

[ -f "$WORK/out/Image" ] || { echo "error: the build produced no Image" >&2; exit 1; }
mkdir -p "$(dirname "$DEST")"
cp "$WORK/out/Image" "$DEST"
sum="$(/usr/bin/shasum -a 256 "$DEST" | awk '{print $1}')"
printf '%s  %s\n' "$sum" "$(basename "$DEST")" > "$DEST.sha256"
# The patches it carries, by name, for vendor-engine.sh to add to the record
# the app reads. The file is named after this Image, so no other build's list
# is read for it, and none is written for the build that shipped.
if [ "$AS_SHIPPED" = "1" ]; then
  rm -f "$DEST.patches"
else
  printf '%s\n' "${OWN_PATCHES[@]%.patch}" > "$DEST.patches"
fi

echo "Image…"
echo "  $DEST"
echo "  $(file -b "$DEST")"
echo "  $(LC_ALL=C grep -a -m1 -o 'Linux version [[:print:]]*' "$DEST")"
echo "  sha256 $sum"
if [ "$AS_SHIPPED" = "1" ]; then
  if [ "$sum" = "$SHIPPED_SHA256" ]; then
    echo "  identical to the Image the engine ships"
  else
    echo "  differs from the Image the engine ships ($SHIPPED_SHA256)"
  fi
fi
