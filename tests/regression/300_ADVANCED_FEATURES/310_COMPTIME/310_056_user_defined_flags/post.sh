#!/bin/bash
# Test that user-defined flags appear in help
#
# Currently FAILING - this test documents the expected behavior.
# Any code can declare flags and they should appear in --help.

set -e

echo "=== Testing: koruc input.kz --help should show user-defined flags ==="

# Capture help output
HELP_OUTPUT=$(koruc input.kz --help 2>&1)

echo "$HELP_OUTPUT"
echo ""

# Check that user-defined flag appears
if echo "$HELP_OUTPUT" | grep -q "my-custom-flag"; then
    echo "=== PASS: --my-custom-flag discovered ==="
else
    echo "=== FAIL: --my-custom-flag NOT found ==="
    echo "Expected: User-defined flags should appear in Backend Compiler Flags"
    exit 1
fi

# Check for second flag
if echo "$HELP_OUTPUT" | grep -q "optimization-level"; then
    echo "=== PASS: --optimization-level discovered ==="
else
    echo "=== FAIL: --optimization-level NOT found ==="
    exit 1
fi
