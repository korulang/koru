#!/bin/bash
# Verify inline annotation syntax produces correct AST

set -e

echo "Getting AST JSON..."
AST_JSON=$(koruc --ast-json input.kz 2>&1 | grep -A 999999 '^{')

echo ""
echo "Test 1: Single annotation"
if echo "$AST_JSON" | grep -q '"comptime"'; then
    echo "✓ Found 'comptime'"
else
    echo "❌ Missing 'comptime'"
    exit 1
fi

echo ""
echo "Test 2: Multiple annotations (comptime|runtime)"
if echo "$AST_JSON" | grep -q '"runtime"'; then
    echo "✓ Found 'runtime'"
else
    echo "❌ Missing 'runtime'"
    exit 1
fi

echo ""
echo "Test 3: Many annotations"
if echo "$AST_JSON" | grep -q '"fuseable"'; then
    echo "✓ Found 'fuseable'"
else
    echo "❌ Missing 'fuseable'"
    exit 1
fi

echo ""
echo "Test 4: Parameterized annotation (opaque string)"
if echo "$AST_JSON" | grep -q '"optimize(level: 3)"'; then
    echo "✓ Found 'optimize(level: 3)' as opaque string"
else
    echo "❌ Missing 'optimize(level: 3)' - should be opaque string!"
    exit 1
fi

echo ""
echo "✅ All inline annotation tests passed!"
