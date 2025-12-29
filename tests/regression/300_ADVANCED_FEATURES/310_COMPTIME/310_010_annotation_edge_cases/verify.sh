#!/bin/bash
# Verify that weird/experimental annotation formats are stored as opaque strings

set -e

echo "Getting AST JSON..."
AST_JSON=$(koruc --ast-json input.kz 2>&1 | grep -A 999999 '^{')

echo ""
echo "Test 1: Colon-separated annotation"
if echo "$AST_JSON" | grep -q 'gpu:metal:half'; then
    echo "✓ Found 'gpu:metal:half' - colon format preserved"
else
    echo "❌ Colon-separated annotation lost"
    exit 1
fi

echo ""
echo "Test 2: Comparison operators"
if echo "$AST_JSON" | grep -q 'version>=2.0'; then
    echo "✓ Found 'version>=2.0' - operators preserved"
else
    echo "❌ Comparison operator annotation lost"
    exit 1
fi

echo ""
echo "Test 3: At-sign syntax"
if echo "$AST_JSON" | grep -q 'inline@500'; then
    echo "✓ Found 'inline@500' - at-sign format preserved"
else
    echo "❌ At-sign annotation lost"
    exit 1
fi

echo ""
echo "Test 4: URL in annotation"
if echo "$AST_JSON" | grep -q 'https://example.com'; then
    echo "✓ Found URL - complex strings preserved"
else
    echo "❌ URL annotation lost"
    exit 1
fi

echo ""
echo "✅ All edge case tests passed!"
echo ""
echo "KEY INSIGHT: Annotations are OPAQUE STRINGS"
echo "Parser doesn't parse inside them - compile-time code does!"
