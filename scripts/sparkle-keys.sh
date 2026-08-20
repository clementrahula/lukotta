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
"$TOOL" -p > "$HERE/.sparkle-public-key" 2>/dev/null || "$TOOL"
printf 'Public key written to .sparkle-public-key\n'
printf 'Back up the private key from your login keychain ("Private key for signing Sparkle updates").\n'
