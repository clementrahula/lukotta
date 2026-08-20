#!/bin/bash
# Build LUKS test volumes covering the layouts Lukotta supports.
#
# The guest shell runs unprivileged, so these can be created without a real
# encrypted drive and without elevation:
#
#   luks2-direct   LUKS2 -> btrfs                 (Arch-style, no LVM)
#   luks2-lvm      LUKS2 -> LVM -> btrfs          (Fedora-style, one volume)
#   luks1-lvm      LUKS1 -> LVM -> two volumes    (Ubuntu-style root + home)
#
# Passphrase for all three: lukotta-test-pass
set -euo pipefail
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
OUT="${1:-$HOME/.lukotta-testvols}"
PASS='lukotta-test-pass'

[ -x "$ENGINE" ] || { echo "error: no engine at $ENGINE" >&2; exit 1; }
mkdir -p "$OUT"

image() {  # name, megabytes
  [ -f "$OUT/$1.img" ] && return 0
  dd if=/dev/zero of="$OUT/$1.img" bs=1m count=0 seek="$2" 2>/dev/null
}

image luks2-direct 600
image luks2-lvm 600
image luks1-lvm 600

echo "Building luks2-direct (LUKS2 -> btrfs)…"
"$ENGINE" shell "$OUT/luks2-direct.img" -c "
set -e
echo -n '$PASS' | cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --batch-mode --key-file - /dev/vda
echo -n '$PASS' | cryptsetup luksOpen --key-file - /dev/vda d
mkfs.btrfs -f -L DIRECTFS /dev/mapper/d >/dev/null 2>&1
cryptsetup luksClose d" 2>&1 | grep -vE '^macOS:' || true

echo "Building luks2-lvm (LUKS2 -> LVM -> btrfs)…"
"$ENGINE" shell "$OUT/luks2-lvm.img" -c "
set -e
echo -n '$PASS' | cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --batch-mode --key-file - /dev/vda
echo -n '$PASS' | cryptsetup luksOpen --key-file - /dev/vda d
pvcreate -ff -y /dev/mapper/d >/dev/null
vgcreate lukottavg /dev/mapper/d >/dev/null
lvcreate -n data -l 100%FREE lukottavg >/dev/null
mkfs.btrfs -f -L LUKOTTATEST /dev/lukottavg/data >/dev/null 2>&1
vgchange -an lukottavg >/dev/null 2>&1
cryptsetup luksClose d" 2>&1 | grep -vE '^macOS:' || true

echo "Building luks1-lvm (LUKS1 -> LVM -> root + home)…"
"$ENGINE" shell "$OUT/luks1-lvm.img" -c "
set -e
echo -n '$PASS' | cryptsetup luksFormat --type luks1 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --batch-mode --key-file - /dev/vda
echo -n '$PASS' | cryptsetup luksOpen --key-file - /dev/vda d
pvcreate -ff -y /dev/mapper/d >/dev/null
vgcreate ubuntuvg /dev/mapper/d >/dev/null
lvcreate -n root -L 220M ubuntuvg >/dev/null
lvcreate -n home -l 100%FREE ubuntuvg >/dev/null
mkfs.btrfs -f -L ROOTFS /dev/ubuntuvg/root >/dev/null 2>&1
mkfs.btrfs -f -L HOMEFS /dev/ubuntuvg/home >/dev/null 2>&1
vgchange -an ubuntuvg >/dev/null 2>&1
cryptsetup luksClose d" 2>&1 | grep -vE '^macOS:' || true

printf 'Test volumes in %s\n' "$OUT"
