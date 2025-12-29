#!/bin/bash

# Simple Koru compiler test runner
# Just checks if .kz files compile to .zig without crashing

set -euo pipefail

KORUC="./zig-out/bin/koruc"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS=0
FAIL=0

echo "========================================="
echo "Simple Koru Compiler Test"
echo "========================================="
echo ""

# Build compiler
echo "Building compiler..."
if ! zig build 2>/dev/null; then
    echo -e "${RED}Failed to build compiler${NC}"
    exit 1
fi

# Test function
test_file() {
    local file=$1
    local name=$(basename "$file")
    printf "Testing %-40s ... " "$name"
    
    # Create temp output
    local output=$(mktemp)
    
    # Try to compile
    if $KORUC "$file" 2>"$output" | grep -q "✓ Compiled"; then
        echo -e "${GREEN}PASS${NC}"
        ((PASS++))
    else
        echo -e "${RED}FAIL${NC}"
        ((FAIL++))
        # Show first line of error
        head -1 "$output" | sed 's/^/  /'
    fi
    
    rm -f "$output"
}

# Test working examples
echo ""
echo "Testing working examples:"
test_file "examples/hello.kz"

# Test integration tests (just see if they parse/compile)
echo ""
echo "Testing integration test files:"
for f in tests/integration/*.kz; do
    [ -f "$f" ] && test_file "$f"
done | head -10  # Just test first 10 to avoid spam

echo ""
echo "========================================="
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "========================================="

exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)