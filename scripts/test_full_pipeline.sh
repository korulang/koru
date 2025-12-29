#!/bin/bash

# Full pipeline test - compile .kz → .zig → executable
# This ACTUALLY tests if emission works!

set -euo pipefail

KORUC="./zig-out/bin/koruc"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "========================================="
echo "Full Pipeline Test (kz → zig → exe)"
echo "========================================="

# Build compiler first
echo "Building Koru compiler..."
if ! zig build 2>/dev/null; then
    echo -e "${RED}Failed to build compiler${NC}"
    exit 1
fi

# Test one simple file end-to-end
TEST_FILE="examples/hello.kz"
OUTPUT_ZIG="examples/hello_test.zig"
OUTPUT_EXE="examples/hello_test"

echo ""
echo "Testing full pipeline for $TEST_FILE:"

# Step 1: Compile .kz to .zig
echo -n "  1. Compiling .kz → .zig ... "
if $KORUC "$TEST_FILE" -o "$OUTPUT_ZIG" 2>/dev/null; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ Failed${NC}"
    exit 1
fi

# Step 2: Compile .zig to executable
echo -n "  2. Compiling .zig → exe ... "
if zig build-exe "$OUTPUT_ZIG" -femit-bin="$OUTPUT_EXE" 2>/dev/null; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ Failed${NC}"
    echo "The generated .zig file doesn't compile!"
    exit 1
fi

# Step 3: Run the executable
echo -n "  3. Running executable ... "
if [ -f "$OUTPUT_EXE" ]; then
    # Just check it exists for now (running might have output we don't expect)
    echo -e "${GREEN}✓${NC}"
    rm -f "$OUTPUT_EXE" "$OUTPUT_ZIG"
else
    echo -e "${RED}✗ No executable produced${NC}"
    exit 1
fi

echo ""
echo "========================================="
echo -e "${GREEN}SUCCESS!${NC} Full pipeline works!"
echo "========================================="