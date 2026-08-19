#!/bin/bash
# Private anylinuxfs entry point used by the native GUI.
# - Finds the runtime relative to Application Support, even under sudo.
# - Validates/normalizes BitLocker numerical recovery passwords.
# - Uses the Linux kernel NTFS3 driver and Finder-friendly permissions.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "${BLM_TESTING:-0}" = "1" ] && [ -n "${BLM_TEST_SUPPORT:-}" ]; then
  SUPPORT="$BLM_TEST_SUPPORT"
else
  case "$SCRIPT_DIR" in
    */bridge) SUPPORT="${SCRIPT_DIR%/bridge}" ;;
    *)
      echo "Error: BitLocker Mounter bridge is not installed in its expected private location." >&2
      exit 70
      ;;
  esac
fi

REAL_ALFS="${BLM_TEST_REAL_ALFS:-$SUPPORT/runtime/anylinuxfs/bin/anylinuxfs}"
DEPS_ROOT="$SUPPORT/runtime/deps"
VALIDATOR="$SCRIPT_DIR/validate-key.sh"

if [ ! -x "$REAL_ALFS" ]; then
  echo "Error: private anylinuxfs runtime is missing. Reopen BitLocker Mounter to repair setup." >&2
  exit 70
fi
if [ ! -x "$VALIDATOR" ]; then
  echo "Error: BitLocker recovery-key validator is missing from the private bridge." >&2
  exit 70
fi

# Derive the actual user's home from .../Library/Application Support/BitLocker Mounter.
# This remains correct when sudo changes $HOME to /var/root.
USER_HOME="$(cd "$SUPPORT/../../.." 2>/dev/null && pwd)"
if [ -z "$USER_HOME" ]; then
  echo "Error: could not resolve the invoking user's home directory." >&2
  exit 70
fi

LIB_PATHS="$(/usr/bin/find "$DEPS_ROOT" -type d -name lib -print 2>/dev/null | /usr/bin/paste -sd ':' -)"
BIN_PATHS="$(/usr/bin/find "$DEPS_ROOT" -type d -name bin -print 2>/dev/null | /usr/bin/paste -sd ':' -)"
export DYLD_LIBRARY_PATH="$LIB_PATHS"
export DYLD_FALLBACK_LIBRARY_PATH="$LIB_PATHS"
export PATH="$SUPPORT/runtime/anylinuxfs/bin:$BIN_PATHS:/usr/bin:/bin:/usr/sbin:/sbin"
export HOME="$USER_HOME"

FIRST="${1:-}"
IS_MOUNT=0
case "$FIRST" in
  mount|/dev/*|disk[0-9]*|raid:*|lvm:*) IS_MOUNT=1 ;;
esac

# This product is intentionally scoped to BitLocker data drives. Without root,
# macOS/anylinuxfs may expose a BitLocker partition only as its GPT type
# ("Microsoft Basic Data"). Mark that generic type as a BitLocker candidate in
# list output so the native GUI asks for the recovery key *before* starting the
# privileged mount probe. A real unlock is still required before anything mounts.
if [ "$FIRST" = "list" ]; then
  LIST_TMP="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/bitlocker-mounter-list.XXXXXX")" || exit 70
  "$REAL_ALFS" "$@" > "$LIST_TMP"
  list_rc=$?
  if [ "$list_rc" -eq 0 ]; then
    /usr/bin/sed 's/Microsoft Basic Data/BitLocker/g' "$LIST_TMP"
  else
    /bin/cat "$LIST_TMP"
  fi
  /bin/rm -f "$LIST_TMP"
  exit "$list_rc"
fi

if [ "$IS_MOUNT" -eq 1 ] && [ -n "${ALFS_PASSPHRASE:-}" ]; then
  NORMALIZED="$("$VALIDATOR" "$ALFS_PASSPHRASE" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "Error: wrong key / invalid passphrase: $NORMALIZED" >&2
    exit 64
  fi
  export ALFS_PASSPHRASE="$NORMALIZED"
fi

if [ "$IS_MOUNT" -eq 1 ]; then
  # The product is intentionally a BitLocker/NTFS data-drive utility. Force the
  # kernel NTFS3 driver and Finder-friendly ownership semantics instead of the
  # slower NTFS-3G compatibility path. Remove any duplicate/competing driver
  # flags first so clap never sees the same option twice.
  explicit_mount=0
  if [ "$FIRST" = "mount" ]; then
    explicit_mount=1
    shift
  fi

  CLEAN_ARGS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ignore-permissions) shift ;;
      -t|--type)
        shift
        [ "$#" -gt 0 ] && shift
        ;;
      --type=*) shift ;;
      *) CLEAN_ARGS+=("$1"); shift ;;
    esac
  done

  if [ "$explicit_mount" -eq 1 ]; then
    exec "$REAL_ALFS" mount --ignore-permissions -t ntfs3 ${CLEAN_ARGS[@]+"${CLEAN_ARGS[@]}"}
  else
    exec "$REAL_ALFS" --ignore-permissions -t ntfs3 ${CLEAN_ARGS[@]+"${CLEAN_ARGS[@]}"}
  fi
fi

exec "$REAL_ALFS" "$@"
