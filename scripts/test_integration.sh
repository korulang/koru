#!/bin/bash

# Koru Integration Test Suite
# Tests the full pipeline: .kz -> .zig -> executable -> run

set -uo pipefail

KORUC="./zig-out/bin/koruc"
ZIG="zig"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test results
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# Results log
RESULTS_LOG=""

echo "========================================="
echo "Koru Integration Test Suite"
echo "========================================="
echo ""

# Build compiler first
echo "Building Koru compiler..."
if ! zig build 2>&1 >/dev/null; then
    echo -e "${RED}Failed to build compiler${NC}"
    exit 1
fi

if [ ! -f "$KORUC" ]; then
    echo -e "${RED}Compiler not found at $KORUC${NC}"
    exit 1
fi

# Create temp directory for test outputs
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

# Function to test a single .kz file
test_koru_file() {
    local kz_file=$1
    local basename=$(basename "$kz_file" .kz)
    local dirname=$(dirname "$kz_file")
    
    printf "%-40s " "$kz_file:"
    
    # Step 1: Compile .kz to .zig
    if ! $KORUC "$kz_file" >"$TEST_DIR/${basename}_koruc.out" 2>"$TEST_DIR/${basename}_koruc.err"; then
        echo -e "${RED}FAIL${NC} (Koru compilation)"
        if [ -s "$TEST_DIR/${basename}_koruc.err" ]; then
            echo "    $(head -1 "$TEST_DIR/${basename}_koruc.err")"
        fi
        RESULTS_LOG="${RESULTS_LOG}\n❌ $kz_file: Koru compilation failed"
        ((FAIL_COUNT++))
        return 1
    fi
    
    local zig_file="${dirname}/${basename}.zig"
    if [ ! -f "$zig_file" ]; then
        echo -e "${RED}FAIL${NC} (No .zig generated)"
        RESULTS_LOG="${RESULTS_LOG}\n❌ $kz_file: No .zig file generated"
        ((FAIL_COUNT++))
        return 1
    fi
    
    # Step 2: Compile .zig to executable
    cd "$dirname"
    if ! $ZIG build-exe "${basename}.zig" -femit-bin="$TEST_DIR/$basename" >"$TEST_DIR/${basename}_zig.out" 2>"$TEST_DIR/${basename}_zig.err"; then
        echo -e "${YELLOW}ZIG-FAIL${NC}"
        if [ -s "$TEST_DIR/${basename}_zig.err" ]; then
            echo "    $(head -1 "$TEST_DIR/${basename}_zig.err")"
        fi
        RESULTS_LOG="${RESULTS_LOG}\n⚠️  $kz_file: Zig compilation failed"
        ((FAIL_COUNT++))
        cd - >/dev/null
        return 1
    fi
    cd - >/dev/null
    
    # Step 3: Run the executable (with timeout to prevent hangs)
    if timeout 2 "$TEST_DIR/$basename" >"$TEST_DIR/${basename}_run.out" 2>"$TEST_DIR/${basename}_run.err"; then
        echo -e "${GREEN}PASS${NC}"
        RESULTS_LOG="${RESULTS_LOG}\n✅ $kz_file: All tests passed"
        ((PASS_COUNT++))
        return 0
    else
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            echo -e "${YELLOW}TIMEOUT${NC}"
            RESULTS_LOG="${RESULTS_LOG}\n⏱️  $kz_file: Execution timeout"
            ((SKIP_COUNT++))
        else
            echo -e "${YELLOW}RUN-FAIL${NC} (exit: $exit_code)"
            RESULTS_LOG="${RESULTS_LOG}\n❌ $kz_file: Runtime error"
            ((FAIL_COUNT++))
        fi
        return 1
    fi
}

echo "Testing all .kz files..."
echo "-----------------------------------------"

# Test root level .kz files (skip koru_std.kz as it's a library)
for kz_file in *.kz; do
    if [ -f "$kz_file" ]; then
        if [ "$kz_file" != "koru_std.kz" ]; then
            test_koru_file "$kz_file"
        fi
    fi
done

# Test integration tests
for kz_file in tests/integration/*.kz; do
    if [ -f "$kz_file" ]; then
        test_koru_file "$kz_file"
    fi
done

# Test examples/*.kz files
for kz_file in examples/*.kz; do
    if [ -f "$kz_file" ]; then
        test_koru_file "$kz_file"
    fi
done


# Summary
echo ""
echo "========================================="
echo "Results Summary:"
echo "-----------------------------------------"
echo -e "$RESULTS_LOG"
echo ""
echo "========================================="
echo "Final Score:"
echo "  ${GREEN}PASSED: $PASS_COUNT${NC}"
echo "  ${RED}FAILED: $FAIL_COUNT${NC}"
echo "  ${YELLOW}TIMEOUT: $SKIP_COUNT${NC}"
echo "========================================="

if [ $FAIL_COUNT -eq 0 ] && [ $SKIP_COUNT -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}$FAIL_COUNT tests failed, $SKIP_COUNT timed out${NC}"
    exit 1
fi