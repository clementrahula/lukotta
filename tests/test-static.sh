#!/bin/bash
set -e
SRC="$(cd "$(dirname "$0")/.." && pwd)"

find "$SRC" -type f \( -name '*.sh' -o -name 'BitLocker Mounter' -o -name 'build.sh' \) -print | while IFS= read -r f; do
  /bin/bash -n "$f" || { echo "FAIL: bash syntax: $f"; exit 1; }
done

if find "$SRC" -type f \( -name '*.applescript' -o -name '*.js' \) | grep -q .; then
  echo "FAIL: legacy JXA/AppleScriptObjC UI source still present"; exit 1
fi
if grep -E 'Delegate\.alloc|ObjC\.import|trap.*RETURN|compatibility mode|fallback UI' "$SRC/BitLocker Mounter" "$SRC"/helpers/*.sh >/dev/null 2>&1; then
  echo "FAIL: legacy fragile UI/runtime code still referenced by executable code"; exit 1
fi

grep -F 'GUI_VERSION="0.7.5"' "$SRC/helpers/bootstrap.sh" >/dev/null
grep -F 'GUI_SHA="701118b5d04368a5153fa0f39d4fb78206509f409d6088797802efbab462fa3f"' "$SRC/helpers/bootstrap.sh" >/dev/null
grep -F 'ALFS_VERSION="0.19.0"' "$SRC/helpers/bootstrap.sh" >/dev/null
grep -F 'ANYLINUXFS_PATH=$BRIDGE/anylinuxfs' "$SRC/BitLocker Mounter" >/dev/null
grep -F '/usr/bin/printf '"'"'mode = "native"\n'"'"' > "$GUI_PREF"' "$SRC/BitLocker Mounter" >/dev/null

echo "PASS: shell syntax, architecture and pinned-release checks"
