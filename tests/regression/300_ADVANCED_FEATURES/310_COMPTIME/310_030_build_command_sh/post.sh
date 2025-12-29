#!/bin/bash
# Test shell command execution

set -e

echo "=== Testing shell command 'hello' ==="
koruc input.kz hello

echo ""
echo "=== Testing shell command 'args' with arguments ==="
koruc input.kz args one two three
