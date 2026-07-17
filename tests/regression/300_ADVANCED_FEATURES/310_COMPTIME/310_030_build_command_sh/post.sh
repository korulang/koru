#!/bin/bash
# Test shell command execution

set -e

echo "=== Testing shell command 'hello' ==="
koruc "$KORU_INPUT" hello

echo ""
echo "=== Testing shell command 'args' with arguments ==="
koruc "$KORU_INPUT" args one two three
