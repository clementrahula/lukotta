#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
# Build LUKS test volumes covering the layouts Lukotta supports.
#
# The guest shell runs unprivileged, so these can be created without a real
# encrypted drive and without elevation:
#
#   luks2-direct   LUKS2 -> btrfs                 (Arch-style, no LVM)
#   luks2-lvm      LUKS2 -> LVM -> btrfs          (Fedora-style, one volume)
#   luks1-lvm      LUKS1 -> LVM -> two volumes    (Ubuntu-style root + home)
#   luks-multi     GPT -> LUKS2 -> LVM -> three   (Fedora-style, and the only
#                  fixture inside a partition, so it is the one the app's own
#                  drive list can see)
#
# With --crowd it also builds thirteen plain NTFS volumes under crowd/, which
# is one more than a Mac can serve at once. That is the fixture for the
# ceiling: how the app behaves as the last place is taken, and what it does
# when there is none. Pair it with LUKOTTA_CAPACITY to reach the ceiling on
# three instead of twelve.
#
# Passphrase for all of them: lukotta-test-pass
#
# Every filesystem here is btrfs because that is the only mkfs the trimmed
# guest still carries. Mounting ext4 and XFS is the kernel's job and is
# unaffected, but neither can be given a fixture from here.
set -euo pipefail
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
# --crowd is a flag wherever it appears, and what is left is the output
# directory. It used to be looked for in $1 or $2 while $1 was also taken as
# the directory, so the documented invocation -- the flag on its own -- made the
# output directory "--crowd" and died in mkdir before building anything.
CROWD=""
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--crowd" ]; then CROWD="yes"; else ARGS+=("$arg"); fi
done
OUT="${ARGS[0]:-$HOME/.lukotta-testvols}"
PASS='lukotta-test-pass'

[ -x "$ENGINE" ] || { echo "error: no engine at $ENGINE" >&2; exit 1; }

# The engine keeps its Linux image inside the application's own directory now,
# and finds it through this. Without it, every engine command here looks in the
# shared ~/.anylinuxfs -- which this app no longer writes to, so on a Mac
# without a separate anylinuxfs install there is no image at all and the first
# fixture build dies with nothing to say for itself.
APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
  "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null)"
export ANYLINUXFS_HOME="$HOME/Library/Application Support/${APP_ID:-com.lukotta}/engine"
mkdir -p "$ANYLINUXFS_HOME/Library/Logs"
mkdir -p "$OUT"

# Sized in bytes rather than "1m": GNU dd wants 1M and BSD dd wants 1m, and a
# Mac with coreutils ahead of /usr/bin has the GNU one, where the lowercase
# spelling is an error rather than a smaller block. With stderr discarded and
# set -e in force, that ended the script on its first fixture and said nothing.
image() {  # name, megabytes
  [ -f "$OUT/$1.img" ] && return 0
  dd if=/dev/zero of="$OUT/$1.img" bs=1048576 count=0 seek="$2" 2>/dev/null
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

# The others are bare containers filling a whole image. The app lists
# partitions, so testing its volume chooser needs a partitioned one; the table
# is written directly because macOS needs root to partition and the guest's
# busybox fdisk cannot write GPT.
echo "Building luks-multi (GPT -> LUKS2 -> LVM -> root + home + backup)…"
if [ ! -f "$OUT/luks-multi.img" ]; then
  : > "$OUT/luks-multi.img"
  python3 "$(dirname "$0")/write-gpt.py" "$OUT/luks-multi.img" --megabytes 900 --type linux-lvm
  "$ENGINE" shell "$OUT/luks-multi.img" -c "
set -e
echo -n '$PASS' | cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --batch-mode --key-file - /dev/vda1
echo -n '$PASS' | cryptsetup luksOpen --key-file - /dev/vda1 d
pvcreate -ff -y /dev/mapper/d >/dev/null
vgcreate fedoravg /dev/mapper/d >/dev/null
lvcreate -n root -L 250M fedoravg >/dev/null
lvcreate -n home -L 250M fedoravg >/dev/null
lvcreate -n backup -l 100%FREE fedoravg >/dev/null
mkfs.btrfs -f -L FEDORAROOT /dev/fedoravg/root >/dev/null 2>&1
mkfs.btrfs -f -L FEDORAHOME /dev/fedoravg/home >/dev/null 2>&1
mkfs.btrfs -f -L FEDORABACKUP /dev/fedoravg/backup >/dev/null 2>&1
vgchange -an fedoravg >/dev/null 2>&1
cryptsetup luksClose d" 2>&1 | grep -vE '^macOS:' || true
fi

# A crowd of them, for the one thing a single fixture cannot show: what the app
# does as the number of open drives approaches what this Mac can serve at once.
# Reaching that by hand means attaching a dozen images one at a time, so it is
# made here instead. Small and plain: the ceiling is about how many can be
# served, not about what is in them.
if [ -n "$CROWD" ]; then
  COUNT="${LUKOTTA_CROWD:-13}"
  echo "Building $COUNT plain volumes for the ceiling (crowd/)…"
  mkdir -p "$OUT/crowd"
  for i in $(seq 1 "$COUNT"); do
    f="$OUT/crowd/drive$i.img"
    [ -f "$f" ] && continue
    dd if=/dev/zero of="$f" bs=1048576 count=0 seek=64 2>/dev/null
    "$ENGINE" shell "$f" -c "mkfs.ntfs -f -F -L CROWD$i /dev/vda" >/dev/null 2>&1
  done
  printf '%s volumes in %s/crowd\n' "$COUNT" "$OUT"
  printf '\nTo watch the ceiling arrive without opening a dozen drives, pin it:\n'
  printf '  LUKOTTA_CAPACITY=3 /Applications/Lukotta.app/Contents/MacOS/Lukotta\n'
  printf 'Then open crowd/drive1.img and crowd/drive2.img and crowd/drive3.img.\n\n'
fi

printf 'Test volumes in %s\n' "$OUT"
printf 'Passphrase: %s\n' "$PASS"
printf '\nTo exercise the volume chooser, attach the partitioned one and run the\napp with disk images included:\n'
printf '  hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage %s/luks-multi.img\n' "$OUT"
printf '  LUKOTTA_INCLUDE_IMAGES=1 /Applications/Lukotta.app/Contents/MacOS/Lukotta\n' 
