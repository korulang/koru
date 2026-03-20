#!/bin/bash
# Test that --help discovers commands from the input file's AST
#
# Currently FAILING - this test documents the expected behavior.
# The help system should parse the input file and discover command.declare.

set -e

echo "=== Testing: koruc input.kz --help should show 'deps' command ==="

# Capture help output
HELP_OUTPUT=$(koruc input.kz --help 2>&1)

echo "$HELP_OUTPUT"
echo ""

# Check that deps command appears in output
if echo "$HELP_OUTPUT" | grep -q "deps"; then
    echo "=== PASS: 'deps' command discovered in help output ==="
else
    echo "=== FAIL: 'deps' command NOT found in help output ==="
    echo "Expected: Commands section should include 'deps' from \$std/deps"
    exit 1
fi
