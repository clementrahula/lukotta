#!/bin/bash
set -u

RESOURCES="${BLM_RESOURCES:?BLM_RESOURCES is not set}"
USER_HOME="${BLM_USER_HOME:-$HOME}"
SUPPORT="$USER_HOME/Library/Application Support/BitLocker Mounter"
RUNTIME="$SUPPORT/runtime"
BRIDGE="$SUPPORT/bridge"
GUI_APP="$SUPPORT/native/BitLocker Mounter.app"
MARKER="$RUNTIME/.ready-bitlocker-mounter-v5"
ROOTFS="$USER_HOME/.anylinuxfs/alpine/rootfs"

[ -f "$MARKER" ] || exit 1
[ -x "$RUNTIME/anylinuxfs/bin/anylinuxfs" ] || exit 1
[ -x "$BRIDGE/anylinuxfs" ] || exit 1
[ -x "$BRIDGE/validate-key.sh" ] || exit 1
[ -d "$GUI_APP" ] || exit 1
GUI_BIN="$(/usr/bin/find "$GUI_APP/Contents/MacOS" -type f -perm -111 -print -quit 2>/dev/null)"
[ -n "$GUI_BIN" ] || exit 1
/usr/bin/codesign --verify --deep --strict "$GUI_APP" >/dev/null 2>&1 || exit 1
[ -d "$ROOTFS" ] || exit 1

BLM_USER_HOME="$USER_HOME" "$BRIDGE/anylinuxfs" --version 2>/dev/null | /usr/bin/grep -q '0\.19\.0' || exit 1
/usr/bin/find "$ROOTFS" -type f -name cryptsetup -print -quit 2>/dev/null | /usr/bin/grep -q . || exit 1
/usr/bin/find "$ROOTFS" -type f \( -name rpc.nfsd -o -name exportfs \) -print -quit 2>/dev/null | /usr/bin/grep -q . || exit 1

exit 0
