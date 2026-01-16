#!/bin/bash
# Run a single regression test (used by run_regression.sh --parallel)
# Usage: ./run_single_test.sh <test_dir>
# Writes SUCCESS or FAILURE to test_dir, outputs single line summary

set -o pipefail

test_dir="$1"
if [ -z "$test_dir" ] || [ ! -d "$test_dir" ]; then
    echo "SKIP: Invalid directory"
    exit 0
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./scripts/regression_lib.sh
source "$SCRIPT_DIR/scripts/regression_lib.sh"

# Ensure category logic starts clean when invoked per-test.
CURRENT_CATEGORY=""

if [ "${REGRESSION_QUIET:-false}" = "true" ]; then
    regression_run_one_test "$test_dir" >/dev/null 2>&1
else
    regression_run_one_test "$test_dir"
fi

TEST_NAME=$(basename "$test_dir")
CATEGORY_DIR="$(dirname "$test_dir")"

if [ -f "$test_dir/BENCHMARK" ]; then
    echo "BENCHMARK: $TEST_NAME"
    exit 0
fi
if [ -f "$test_dir/TODO" ]; then
    echo "TODO: $TEST_NAME"
    exit 0
fi
if [ -f "$CATEGORY_DIR/SKIP" ]; then
    echo "SKIP: $TEST_NAME"
    exit 0
fi
if [ -f "$test_dir/SKIP" ]; then
    echo "SKIP: $TEST_NAME"
    exit 0
fi
if [ -f "$test_dir/BROKEN" ]; then
    reason=$(head -1 "$test_dir/FAILURE" 2>/dev/null || echo "broken-test")
    echo "FAIL: $TEST_NAME ($reason)"
    exit 1
fi
if [ -f "$test_dir/FAILURE" ]; then
    reason=$(head -1 "$test_dir/FAILURE" 2>/dev/null)
    if [ -n "$reason" ]; then
        echo "FAIL: $TEST_NAME ($reason)"
    else
        echo "FAIL: $TEST_NAME"
    fi
    exit 1
fi
if [ -f "$test_dir/SUCCESS" ]; then
    echo "PASS: $TEST_NAME"
    exit 0
fi

echo "FAIL: $TEST_NAME (unknown)"
exit 1
