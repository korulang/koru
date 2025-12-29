#!/bin/bash
# Verify vertical annotation syntax produces correct AST

set -e

echo "Getting AST JSON..."
AST_JSON=$(koruc --ast-json input.kz 2>&1 | grep -A 999999 '^{')

echo ""
echo "Test 1: Vertical bullets produce annotations"
if echo "$AST_JSON" | grep -q '"comptime"'; then
    echo "✓ Found 'comptime' from vertical"
else
    echo "❌ Missing 'comptime' from vertical syntax"
    exit 1
fi

if echo "$AST_JSON" | grep -q '"fuseable"'; then
    echo "✓ Found 'fuseable' from vertical"
else
    echo "❌ Missing 'fuseable' from vertical syntax"
    exit 1
fi

echo ""
echo "Test 2: Vertical parameterized annotations (opaque strings)"
if echo "$AST_JSON" | grep -q '"optimize(level: 3)"'; then
    echo "✓ Found 'optimize(level: 3)' as opaque string"
else
    echo "❌ Missing 'optimize(level: 3)'"
    exit 1
fi

if echo "$AST_JSON" | grep -q '"inline(threshold: 500)"'; then
    echo "✓ Found 'inline(threshold: 500)' as opaque string"
else
    echo "❌ Missing 'inline(threshold: 500)'"
    exit 1
fi

if echo "$AST_JSON" | grep -q '"gpu(target: \"metal\", precision: \"half\")"' || \
   echo "$AST_JSON" | grep -q 'gpu(target: "metal"'; then
    echo "✓ Found complex 'gpu(...)' annotation"
else
    echo "❌ Missing complex gpu annotation"
    exit 1
fi

echo ""
echo "Test 3: Mixed simple and parameterized"
if echo "$AST_JSON" | grep -q '"profile(sample_rate: 1000)"'; then
    echo "✓ Found 'profile(sample_rate: 1000)'"
else
    echo "❌ Missing 'profile(sample_rate: 1000)'"
    exit 1
fi

echo ""
echo "✅ All vertical annotation tests passed!"
echo ""
echo "NOTE: Vertical ~[-a -b] should produce SAME annotations as inline ~[a|b]"
