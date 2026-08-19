#!/bin/bash
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
"$HERE/test-static.sh"
"$HERE/test-key-validator.sh"
"$HERE/test-proxy.sh"
"$HERE/test-launcher-flow.sh"
"$HERE/test-launcher-errors.sh"
echo "ALL TESTS PASSED"
