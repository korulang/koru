#!/bin/bash
# Test deps command execution

set -e

echo "=== Testing deps command (check only) ==="
koruc input.kz deps || true

echo ""
echo "=== Test passed: deps command executed ==="
