#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# Build the guest's AFP server, netatalk 4.5.0 as Alpine 3.24 builds it, with vendor/patches/netatalk-*.patch.
#   ./scripts/build-afpd.sh
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1
OUT="$HERE/vendor/engine-built"
VERSION="4.5.0"
SHA256="${NETATALK_SHA256:-}"
command -v docker >/dev/null 2>&1 || {
  echo "error: docker is needed to build this, and only to build it" >&2
  exit 2
}
docker version >/dev/null 2>&1 || {
  echo "error: docker is installed but its daemon is not running" >&2
  exit 2
}
mkdir -p "$OUT"
WORK="$(mktemp -d)"
cp vendor/patches/netatalk-*.patch "$WORK/"
echo "Building afpd for the guest (netatalk $VERSION, Alpine 3.24, aarch64, musl)…"
docker run --rm --platform linux/arm64 -v "$WORK:/out" alpine:3.24 sh -c "
set -e
exec >/out/build.log 2>&1
apk add --no-cache build-base acl-dev attr-dev bstring-dev cmark db-dev file iniparser-dev \
  libevent-dev libgcrypt-dev libtirpc-dev linux-headers mariadb-dev meson ninja sqlite-dev \
  talloc-dev xz patch
cd /tmp
wget -q https://github.com/Netatalk/netatalk/releases/download/netatalk-${VERSION//./-}/netatalk-$VERSION.tar.xz
sha256sum netatalk-$VERSION.tar.xz | cut -d' ' -f1 > /out/netatalk.sha256
[ -z '$SHA256' ] || [ \"\$(cat /out/netatalk.sha256)\" = '$SHA256' ]
tar xf netatalk-$VERSION.tar.xz
cd netatalk-$VERSION
for p in /out/netatalk-*.patch; do patch -p1 < \"\$p\"; basename \"\$p\" .patch >> /out/afpd.patches; done
meson setup build --prefix=/usr --sysconfdir=/etc --localstatedir=/var --buildtype=plain \
  -Ddefault_library=shared -Dwith-acls=true -Dwith-appletalk=true -Dwith-cracklib=false \
  -Dwith-docs= -Dwith-dtrace=false -Dwith-init-style=openrc -Dwith-kerberos=false \
  -Dwith-krbV-uam=false -Dwith-init-hooks=false -Dwith-install-hooks=false -Dwith-ldap=false \
  -Dwith-ldsoconf=false -Dwith-libiconv=false -Dwith-lockfile-path=/run/lock -Dwith-overwrite=true \
  -Dwith-pam=false -Dwith-statedir-path=/var/lib -Dwith-tcp-wrappers=false -Dwith-tests=false \
  -Dwith-zeroconf=false
meson compile -C build etc/afpd/afpd:executable
cp build/etc/afpd/afpd /out/afpd
" >/dev/null 2>&1 || true
[ -f "$WORK/afpd" ] || {
  echo "error: the build produced no afpd" >&2
  tail -n 20 "$WORK/build.log" >&2 2>/dev/null
  exit 1
}
cp "$WORK/afpd" "$OUT/afpd"
cp "$WORK/afpd.patches" "$OUT/afpd.patches"
cp "$WORK/netatalk.sha256" "$OUT/netatalk.sha256"
chmod 0755 "$OUT/afpd"
printf 'afpd from netatalk %s (sha256 %s)\n  patches: %s\n  %s bytes\n' "$VERSION" \
  "$(cut -c1-12 "$OUT/netatalk.sha256")" "$(paste -sd' ' "$OUT/afpd.patches")" \
  "$(wc -c < "$OUT/afpd" | tr -d ' ')"
