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

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

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
    echo -e "${CYAN}📊 BENCH${NC}  ${DIM}$TEST_NAME${NC}"
    exit 0
fi
if [ -f "$test_dir/TODO" ]; then
    echo -e "${YELLOW}📝 TODO ${NC}  ${DIM}$TEST_NAME${NC}"
    exit 0
fi
if [ -f "$CATEGORY_DIR/SKIP" ]; then
    echo -e "${CYAN}⏭️  SKIP ${NC}  ${DIM}$TEST_NAME${NC}"
    exit 0
fi
if [ -f "$test_dir/SKIP" ]; then
    echo -e "${CYAN}⏭️  SKIP ${NC}  ${DIM}$TEST_NAME${NC}"
    exit 0
fi
if [ -f "$test_dir/BROKEN" ]; then
    reason=$(head -1 "$test_dir/FAILURE" 2>/dev/null || echo "broken-test")
    echo -e "${RED}🔧 BROKEN${NC} $TEST_NAME ${DIM}($reason)${NC}"
    exit 1
fi
if [ -f "$test_dir/FAILURE" ]; then
    reason=$(head -1 "$test_dir/FAILURE" 2>/dev/null)
    if [ -n "$reason" ]; then
        echo -e "${RED}❌ FAIL ${NC}  $TEST_NAME ${DIM}($reason)${NC}"
    else
        echo -e "${RED}❌ FAIL ${NC}  $TEST_NAME"
    fi
    exit 1
fi
if [ -f "$test_dir/SUCCESS" ]; then
    echo -e "${GREEN}✅ PASS ${NC}  ${DIM}$TEST_NAME${NC}"
    exit 0
fi

echo -e "${RED}❌ FAIL ${NC}  $TEST_NAME ${DIM}(unknown)${NC}"
exit 1
