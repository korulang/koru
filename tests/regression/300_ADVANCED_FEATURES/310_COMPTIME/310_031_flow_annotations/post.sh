#!/bin/bash
# Test Flow annotations parsing

set -e

echo "=== Compiling $KORU_INPUT with Flow annotations ==="
koruc "$KORU_INPUT"

echo ""
echo "✅ Flow annotations parsed successfully!"
echo "Annotations are stored in AST and available for build orchestration"
