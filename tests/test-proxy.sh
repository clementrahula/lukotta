#!/bin/bash
set -e
SRC="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_FAKE="$TMP/home"
SUPPORT="$HOME_FAKE/Library/Application Support/BitLocker Mounter"
BRIDGE="$SUPPORT/bridge"
mkdir -p "$BRIDGE" "$SUPPORT/runtime/deps" "$SUPPORT/runtime/anylinuxfs/bin"
cp "$SRC/helpers/alfs-proxy.sh" "$BRIDGE/anylinuxfs"
cp "$SRC/helpers/validate-key.sh" "$BRIDGE/validate-key.sh"
chmod 755 "$BRIDGE/anylinuxfs" "$BRIDGE/validate-key.sh"

FAKE="$TMP/fake-alfs"
cat > "$FAKE" <<'FAKEEOF'
#!/bin/bash
if [ "${1:-}" = "list" ]; then
  echo '/dev/disk9 (external, physical):'
  echo '   1: Microsoft Basic Data TEST 100.0 GB disk9s1'
  exit 0
fi
printf 'PASS=%s\n' "${ALFS_PASSPHRASE:-}"
printf 'ARGS='
printf '<%s>' "$@"
printf '\n'
FAKEEOF
chmod 755 "$FAKE"

VALID="110011-220022-330033-440044-550055-660066-700007-711711"
UNDASHED="110011220022330033440044550055660066700007711711"

out="$(BLM_TESTING=1 BLM_TEST_SUPPORT="$SUPPORT" BLM_TEST_REAL_ALFS="$FAKE" ALFS_PASSPHRASE="$UNDASHED" "$BRIDGE/anylinuxfs" mount /dev/disk9s1)"
printf '%s\n' "$out" | grep -F "PASS=$VALID" >/dev/null
printf '%s\n' "$out" | grep -F 'ARGS=<mount><--ignore-permissions><-t><ntfs3></dev/disk9s1>' >/dev/null

out="$(BLM_TESTING=1 BLM_TEST_SUPPORT="$SUPPORT" BLM_TEST_REAL_ALFS="$FAKE" ALFS_PASSPHRASE="$VALID" "$BRIDGE/anylinuxfs" mount --ignore-permissions --type ntfs-3g /dev/disk9s1)"
printf '%s\n' "$out" | grep -F 'ARGS=<mount><--ignore-permissions><-t><ntfs3></dev/disk9s1>' >/dev/null

out="$(BLM_TESTING=1 BLM_TEST_SUPPORT="$SUPPORT" BLM_TEST_REAL_ALFS="$FAKE" "$BRIDGE/anylinuxfs" list)"
printf '%s\n' "$out" | grep -F 'BitLocker TEST 100.0 GB disk9s1' >/dev/null || { echo "FAIL: Microsoft Basic Data was not surfaced as a BitLocker candidate"; exit 1; }
if printf '%s\n' "$out" | grep -F 'Microsoft Basic Data' >/dev/null; then
  echo "FAIL: generic Microsoft Basic Data marker leaked through BitLocker-only list policy"; exit 1
fi
if printf '%s\n' "$out" | grep -F 'ntfs3' >/dev/null; then
  echo "FAIL: ntfs3 injected into non-mount command"; exit 1
fi

# A BitLocker user password is forwarded verbatim, not forced into recovery-key
# shape. Spaces and punctuation are significant.
PW='Correct Horse Battery! 42'
out="$(BLM_TESTING=1 BLM_TEST_SUPPORT="$SUPPORT" BLM_TEST_REAL_ALFS="$FAKE" ALFS_PASSPHRASE="$PW" "$BRIDGE/anylinuxfs" mount /dev/disk9s1)"
printf '%s\n' "$out" | grep -F "PASS=$PW" >/dev/null || { echo "FAIL: BitLocker user password was not forwarded verbatim"; exit 1; }

# Recovery-shaped input is still validated strictly, and the failure is
# classified so the UI can keep the user in the retry flow.
set +e
invalid_out="$(BLM_TESTING=1 BLM_TEST_SUPPORT="$SUPPORT" BLM_TEST_REAL_ALFS="$FAKE" ALFS_PASSPHRASE="110011-220022-330033-440044-550055-660066-700007-711712" "$BRIDGE/anylinuxfs" mount /dev/disk9s1 2>&1)"
invalid_rc=$?
set -e
[ "$invalid_rc" -ne 0 ] || { echo "FAIL: proxy accepted a recovery key with a bad checksum"; exit 1; }
printf '%s\n' "$invalid_out" | grep -F 'wrong key / invalid passphrase' >/dev/null || { echo "FAIL: invalid recovery key is not classified as an encryption/passphrase error for retry UX"; exit 1; }
printf '%s\n' "$invalid_out" | grep -F 'Group 8' >/dev/null || { echo "FAIL: proxy discarded the precise validator message"; exit 1; }

# Regression: bash 3.2 aborts on "${arr[@]}" when the array is empty and set -u
# is active. Every argument below is stripped by the rewriter, so the array is
# empty by the time the real binary is invoked.
for bare in "mount" "mount --ignore-permissions" "mount -t ntfs"; do
  set +e
  bare_out="$(BLM_TESTING=1 BLM_TEST_SUPPORT="$SUPPORT" BLM_TEST_REAL_ALFS="$FAKE" "$BRIDGE/anylinuxfs" $bare 2>&1)"
  bare_rc=$?
  set -e
  if printf '%s\n' "$bare_out" | grep -F 'unbound variable' >/dev/null; then
    echo "FAIL: empty argument list crashes the bridge ($bare)"; exit 1
  fi
  [ "$bare_rc" -eq 0 ] || { echo "FAIL: bridge failed on '$bare' (rc=$bare_rc): $bare_out"; exit 1; }
done

echo "PASS: anylinuxfs bridge normalization and mount policy"
