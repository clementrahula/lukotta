#!/bin/bash
set -e
SRC="$(cd "$(dirname "$0")/.." && pwd)"

run_setup_failure_test() {
  TMP="$(mktemp -d)"
  HOME="$TMP/User With Space"; export HOME
  APP="$TMP/Test App.app"; RES="$APP/Contents/Resources"; MAC="$APP/Contents/MacOS"
  mkdir -p "$RES/helpers" "$MAC" "$HOME"
  cp "$SRC/BitLocker Mounter" "$MAC/BitLocker Mounter"; chmod 755 "$MAC/BitLocker Mounter"
  for x in alfs-proxy validate-key; do printf '#!/bin/bash\nexit 0\n' > "$RES/helpers/$x.sh"; chmod 755 "$RES/helpers/$x.sh"; done
  cat > "$RES/helpers/runtime-ready.sh" <<'S'
#!/bin/bash
exit 1
S
  cat > "$RES/helpers/bootstrap.sh" <<'S'
#!/bin/bash
echo 'PROGRESS|25|Downloading simulated dependency'
echo 'ERROR|77|Exact simulated dependency failure: checksum mismatch' >&2
exit 77
S
  chmod 755 "$RES/helpers/runtime-ready.sh" "$RES/helpers/bootstrap.sh"

  FAKE_OSA="$TMP/fake-osa"
  cat > "$FAKE_OSA" <<'S'
#!/bin/bash
args="$*"
script="$(cat)"
if printf '%s' "$script" | grep -F 'buttons {"Quit", "Set Up"}' >/dev/null; then
  echo 'Set Up'
elif printf '%s' "$script" | grep -F 'buttons {"Quit", "Open Log", "Retry"}' >/dev/null; then
  printf '%s\n' "$args" > "$HOME/failure-args.txt"
  echo 'Quit'
fi
S
  chmod 755 "$FAKE_OSA"

  set +e
  BLM_OSASCRIPT="$FAKE_OSA" BLM_OPEN_CMD=/bin/false BLM_STARTUP_WAIT=0 "$MAC/BitLocker Mounter" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { echo 'FAIL: setup failure incorrectly returned success'; rm -rf "$TMP"; return 1; }
  grep -F 'Exact simulated dependency failure: checksum mismatch' "$HOME/Library/Application Support/BitLocker Mounter/logs/setup-v5.log" >/dev/null || { echo 'FAIL: exact setup error missing from log'; rm -rf "$TMP"; return 1; }
  grep -F 'Exact simulated dependency failure: checksum mismatch' "$HOME/failure-args.txt" >/dev/null || { echo 'FAIL: exact setup reason not surfaced to failure dialog'; rm -rf "$TMP"; return 1; }
  rm -rf "$TMP"
}

run_native_failure_test() {
  TMP="$(mktemp -d)"
  HOME="$TMP/User With Space"; export HOME
  APP="$TMP/Test App.app"; RES="$APP/Contents/Resources"; MAC="$APP/Contents/MacOS"
  SUPPORT="$HOME/Library/Application Support/BitLocker Mounter"
  mkdir -p "$RES/helpers" "$MAC" "$HOME" "$SUPPORT/native/BitLocker Mounter.app" "$SUPPORT/runtime"
  cp "$SRC/BitLocker Mounter" "$MAC/BitLocker Mounter"; chmod 755 "$MAC/BitLocker Mounter"
  for x in alfs-proxy validate-key; do printf '#!/bin/bash\nexit 0\n' > "$RES/helpers/$x.sh"; chmod 755 "$RES/helpers/$x.sh"; done
  cat > "$RES/helpers/runtime-ready.sh" <<'S'
#!/bin/bash
exit 0
S
  printf '#!/bin/bash\nexit 0\n' > "$RES/helpers/bootstrap.sh"
  chmod 755 "$RES/helpers/runtime-ready.sh" "$RES/helpers/bootstrap.sh"

  FAKE_OSA="$TMP/fake-osa"
  cat > "$FAKE_OSA" <<'S'
#!/bin/bash
args="$*"
script="$(cat)"
if printf '%s' "$script" | grep -F 'verified native interface exited' >/dev/null; then
  printf '%s\n' "$args" > "$HOME/native-failure-args.txt"
fi
S
  chmod 755 "$FAKE_OSA"

  FAKE_OPEN="$TMP/fake-open"
  cat > "$FAKE_OPEN" <<'S'
#!/bin/bash
stderr_path=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = '--stderr' ]; then shift; stderr_path="$1"; fi
  shift || true
done
[ -n "$stderr_path" ] && echo 'Exact native loader failure' > "$stderr_path"
exit 42
S
  chmod 755 "$FAKE_OPEN"

  set +e
  BLM_OSASCRIPT="$FAKE_OSA" BLM_OPEN_CMD="$FAKE_OPEN" BLM_STARTUP_WAIT=1 "$MAC/BitLocker Mounter" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 42 ] || { echo "FAIL: native failure exit code was $rc, expected 42"; rm -rf "$TMP"; return 1; }
  grep -F 'Exact native loader failure' "$HOME/native-failure-args.txt" >/dev/null || { echo 'FAIL: native loader reason not surfaced'; rm -rf "$TMP"; return 1; }
  rm -rf "$TMP"
}

run_setup_failure_test
run_native_failure_test
echo 'PASS: setup/native startup failures surface exact reasons'
