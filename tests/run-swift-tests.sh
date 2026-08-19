#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(mktemp -d)/fulocker-tests"
swiftc -target arm64-apple-macos15.0 \
  "$HERE/src/Engine.swift" "$HERE/src/Mounter.swift" "$HERE/tests/swift/main.swift" \
  -o "$BIN"
"$BIN"
