#!/bin/bash
# Test that --help discovers flags from the input file's AST
#
# Currently FAILING - this test documents the expected behavior.
# The help system should parse the input file and discover flag.declare.

set -e

echo "=== Testing: koruc input.kz --help should show backend flags ==="

# Capture help output
HELP_OUTPUT=$(koruc input.kz --help 2>&1)

echo "$HELP_OUTPUT"
echo ""

# Check that backend flags section appears
if echo "$HELP_OUTPUT" | grep -q "Backend Compiler Flags"; then
    echo "=== PASS: Backend Compiler Flags section found ==="
else
    echo "=== FAIL: Backend Compiler Flags section NOT found ==="
    echo "Expected: Help should include 'Backend Compiler Flags' section"
    exit 1
fi

# Check for specific flags
if echo "$HELP_OUTPUT" | grep -q "\-\-ccp"; then
    echo "=== PASS: --ccp flag discovered ==="
else
    echo "=== FAIL: --ccp flag NOT found ==="
    exit 1
fi
