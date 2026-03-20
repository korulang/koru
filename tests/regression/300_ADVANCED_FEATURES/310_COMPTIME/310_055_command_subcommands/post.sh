#!/bin/bash
# Test that command.declare supports subcommands
#
# This test verifies that subcommands declared in command.declare
# appear in the help output. Currently FAILING until implemented.

set -e

echo "=== Testing: koruc input.kz --help should show subcommands ==="

# Capture help output
HELP_OUTPUT=$(koruc input.kz --help 2>&1)

echo "$HELP_OUTPUT"
echo ""

# First verify deps appears at all
if ! echo "$HELP_OUTPUT" | grep -q "deps"; then
    echo "=== FAIL: 'deps' command not found (prerequisite) ==="
    exit 1
fi

# The actual test: subcommands should be indicated
# Either "deps install" on its own line, or "deps [install|check]" compact form
if echo "$HELP_OUTPUT" | grep -qE "deps install|deps \[.*install"; then
    echo "=== PASS: Subcommand 'install' indicated for deps ==="
else
    echo "=== FAIL: Subcommand 'install' NOT shown for deps ==="
    echo "Expected: Help should indicate that deps has subcommands"
    echo "See input.kz for aspirational syntax"
    exit 1
fi
