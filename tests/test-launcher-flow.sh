#!/bin/bash
set -e
SRC="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME="$TMP/Test User"
export HOME
APP="$TMP/Test App.app"
RES="$APP/Contents/Resources"
MAC="$APP/Contents/MacOS"
mkdir -p "$RES/helpers" "$MAC" "$HOME"
cp "$SRC/BitLocker Mounter" "$MAC/BitLocker Mounter"
chmod 755 "$MAC/BitLocker Mounter"

cat > "$RES/helpers/alfs-proxy.sh" <<'S'
#!/bin/bash
exit 0
S
cat > "$RES/helpers/validate-key.sh" <<'S'
#!/bin/bash
exit 0
S
cat > "$RES/helpers/runtime-ready.sh" <<'S'
#!/bin/bash
SUPPORT="$HOME/Library/Application Support/BitLocker Mounter"
[ -f "$SUPPORT/runtime/.test-ready" ]
S
cat > "$RES/helpers/bootstrap.sh" <<'S'
#!/bin/bash
SUPPORT="$HOME/Library/Application Support/BitLocker Mounter"
mkdir -p "$SUPPORT/runtime" "$SUPPORT/native/BitLocker Mounter.app/Contents/MacOS"
echo 'PROGRESS|10|Downloading test component'
echo 'PROGRESS|55|Installing test component'
cat > "$SUPPORT/native/BitLocker Mounter.app/Contents/MacOS/native-test" <<'N'
#!/bin/bash
exit 0
N
chmod 755 "$SUPPORT/native/BitLocker Mounter.app/Contents/MacOS/native-test"
touch "$SUPPORT/runtime/.test-ready"
echo 'PROGRESS|100|Ready'
S
chmod 755 "$RES/helpers/"*.sh

FAKE_OSA="$TMP/fake-osascript"
cat > "$FAKE_OSA" <<'S'
#!/bin/bash
script="$(cat)"
case "$script" in
  *'buttons {"Quit", "Set Up"}'*) printf 'Set Up\n' ;;
  *'buttons {"Quit", "Open Log", "Retry"}'*) printf 'Quit\n' ;;
  *) : ;;
esac
S
chmod 755 "$FAKE_OSA"


FAKE_OPEN="$TMP/fake-open"
cat > "$FAKE_OPEN" <<'S'
#!/bin/bash
printf '%s\n' "$@" > "$HOME/open-args.txt"
/bin/sleep 1
S
chmod 755 "$FAKE_OPEN"

BLM_OSASCRIPT="$FAKE_OSA" BLM_OPEN_CMD="$FAKE_OPEN" BLM_STARTUP_WAIT=0.1 "$MAC/BitLocker Mounter"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "$HOME/open-args.txt" ] && break
  /bin/sleep 0.1
done
[ -f "$HOME/open-args.txt" ] || { echo 'FAIL: native GUI was not launched through open'; exit 1; }
expected="ANYLINUXFS_PATH=$HOME/Library/Application Support/BitLocker Mounter/bridge/anylinuxfs"
grep -F -- "$expected" "$HOME/open-args.txt" >/dev/null || { echo 'FAIL: ANYLINUXFS_PATH was not passed through LaunchServices'; cat "$HOME/open-args.txt"; exit 1; }
grep -F -- '-W' "$HOME/open-args.txt" >/dev/null || { echo 'FAIL: launcher did not use open -W startup monitoring'; exit 1; }
[ -s "$HOME/Library/Application Support/BitLocker Mounter/logs/setup-v5.log" ] || { echo 'FAIL: setup log not written'; exit 1; }

PREF="$HOME/Library/Application Support/com.anylinuxfs.gui/preferences.toml"
[ -f "$PREF" ] || { echo "FAIL: native elevation preference was not created"; exit 1; }
grep -F 'mode = "native"' "$PREF" >/dev/null || { echo "FAIL: native elevation mode was not forced"; exit 1; }

echo 'PASS: first-run setup -> readiness -> native GUI launch flow'
