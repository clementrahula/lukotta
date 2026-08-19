#!/bin/bash
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
"$HERE/test-key-validator.sh"
"$HERE/run-swift-tests.sh"
echo "ALL TESTS PASSED"
