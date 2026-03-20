#!/bin/bash
# Test that command.declare supports subcommands
#
# Currently FAILING - this test documents the expected behavior.
# command.declare should parse and display subcommands in help.
#
# The deps command has an "install" subcommand that should be shown.

set -e

echo "=== Testing: koruc input.kz --help should show deps subcommands ==="

# Capture help output
HELP_OUTPUT=$(koruc input.kz --help 2>&1)

echo "$HELP_OUTPUT"
echo ""

# First check that deps command appears at all
if echo "$HELP_OUTPUT" | grep -q "deps"; then
    echo "=== PASS: 'deps' command discovered ==="
else
    echo "=== FAIL: 'deps' command NOT found ==="
    echo "This is a prerequisite - deps command should appear in help"
    exit 1
fi

# Check that install subcommand is indicated somehow
# Could be "deps install" or "deps [install]" or similar
if echo "$HELP_OUTPUT" | grep -qi "install.*dep\|dep.*install"; then
    echo "=== PASS: 'install' subcommand indicated for deps ==="
else
    echo "=== FAIL: 'install' subcommand NOT shown for deps ==="
    echo "Expected: Help should indicate that deps has an 'install' subcommand"
    exit 1
fi
