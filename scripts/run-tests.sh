#!/bin/bash
# Everything that can be checked without a drive attached.
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
"$HERE/scripts/test-key-validator.sh"
swift run --package-path "$HERE" LukottaTests
