#!/bin/bash
# Verify that annotations appear in AST JSON

set -e

AST_JSON=$(koruc --ast-json input.kz 2>&1 | grep -A 999999 '^{')

echo "Checking for 'comptime' annotation..."
if echo "$AST_JSON" | grep -q '"comptime"'; then
    echo "✓ Found 'comptime' annotation in AST"
else
    echo "❌ 'comptime' annotation NOT found in AST"
    exit 1
fi

echo "Checking for 'runtime' annotation..."
if echo "$AST_JSON" | grep -q '"runtime"'; then
    echo "✓ Found 'runtime' annotation in AST"
else
    echo "❌ 'runtime' annotation NOT found in AST"
    exit 1
fi

echo "Checking for 'fuseable' annotation..."
if echo "$AST_JSON" | grep -q '"fuseable"'; then
    echo "✓ Found 'fuseable' annotation in AST"
else
    echo "❌ 'fuseable' annotation NOT found in AST"
    exit 1
fi

echo "Checking for 'inline' annotation..."
if echo "$AST_JSON" | grep -q '"inline"'; then
    echo "✓ Found 'inline' annotation in AST"
else
    echo "❌ 'inline' annotation NOT found in AST"
    exit 1
fi

echo ""
echo "✅ All annotations found in AST!"
