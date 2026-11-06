#!/usr/bin/env bash
# Run the mpv-svp test suite.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0

for test in "$HERE"/test-*.sh; do
    echo
    echo "########## $(basename "$test") ##########"
    if ! "$test"; then
        failed=1
    fi
done

echo
if [[ "$failed" -ne 0 ]]; then
    echo "some tests FAILED"
    exit 1
fi
echo "all tests passed"
