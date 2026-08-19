#!/bin/bash
# Reassemble BitLocker Mounter.app from this Source directory.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/BitLocker Mounter.app}"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources/helpers"
cp "$HERE/Info.plist" "$OUT/Contents/Info.plist"
cp "$HERE/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
cp "$HERE/anylinuxfs.entitlements" "$OUT/Contents/Resources/anylinuxfs.entitlements"
cp "$HERE/BitLocker Mounter" "$OUT/Contents/MacOS/BitLocker Mounter"
cp "$HERE/helpers/"*.sh "$OUT/Contents/Resources/helpers/"
cp "$HERE/README-app.txt" "$OUT/Contents/Resources/README.txt"
chmod 755 "$OUT/Contents/MacOS/BitLocker Mounter" "$OUT/Contents/Resources/helpers/"*.sh
printf 'Built %s\n' "$OUT"
