#!/bin/bash
# Generate the EdDSA keypair Sparkle uses to sign updates.
#
# Run once. The private key is stored in the login keychain and is NOT
# recoverable: lose it and every installed copy becomes unupdatable, because
# clients only ever trust this one key. Back it up.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$(find "$HERE/.build" -name generate_keys -type f -perm -111 -print -quit 2>/dev/null || true)"
[ -n "$TOOL" ] || {
  echo "error: generate_keys not found. Run 'swift build' first so Sparkle is resolved." >&2
  exit 1; }
# Under Lukotta's own keychain account. Sparkle's default is one global key per
# user, shared by every app that developer ships; a separate account keeps this
# project's key its own, and leaves any existing one alone.
ACCOUNT="${LUKOTTA_SPARKLE_ACCOUNT:-lukotta}"
"$TOOL" --account "$ACCOUNT" >/dev/null 2>&1 || true
"$TOOL" --account "$ACCOUNT" -p > "$HERE/.sparkle-public-key"
printf 'Public key written to .sparkle-public-key (tracked; it is not a secret).\n'
printf 'The private key is in the login keychain under account "%s".\n' "$ACCOUNT"
printf 'Export it with: %s --account %s -x <file>\n' "$TOOL" "$ACCOUNT"
printf 'Back it up. Lose it and every installed copy becomes unupdatable.\n'
