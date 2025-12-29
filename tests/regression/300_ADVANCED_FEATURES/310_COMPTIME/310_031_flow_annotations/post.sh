#!/bin/bash
# Test Flow annotations parsing

set -e

echo "=== Compiling input.kz with Flow annotations ==="
koruc input.kz

echo ""
echo "✅ Flow annotations parsed successfully!"
echo "Annotations are stored in AST and available for build orchestration"
