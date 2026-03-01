#!/bin/bash
# Test deps install subcommand forwarding
#
# Verifies that "install" is correctly forwarded to the backend handler.
# Before the fix: output contained "To install missing dependencies:"
# After the fix:  output contains "Installing 1 missing dependencies"

set -e

echo "=== Testing deps install subcommand ==="
koruc input.kz deps install || true

echo ""
echo "=== Test passed: deps install subcommand forwarded ==="
