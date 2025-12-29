#!/bin/bash
# Verify Source parameters appear correctly in AST JSON

set -e

echo "Getting AST JSON..."
AST_JSON=$(koruc --ast-json input.kz 2>&1 | grep -A 999999 '^{')

echo ""
echo "Test 1: Source type recognized"
if echo "$AST_JSON" | grep -q '"type": "Source"'; then
    echo "✓ Found Source type in AST"
else
    echo "❌ Source type not found in AST"
    exit 1
fi

echo ""
echo "Test 2: is_source flag set to true"
if echo "$AST_JSON" | grep -q '"is_source": true'; then
    echo "✓ Found is_source: true flag"
else
    echo "❌ is_source flag not set correctly"
    exit 1
fi

echo ""
echo "Test 3: Field names present"
if echo "$AST_JSON" | grep -q '"name": "code"' && echo "$AST_JSON" | grep -q '"name": "template"'; then
    echo "✓ Found field names 'code' and 'template'"
else
    echo "❌ Field names not found"
    exit 1
fi

echo ""
echo "✅ All Source parameter tests passed!"
echo ""
echo "KEY INSIGHT: Source parameters enable passing raw source code as data"
echo "Use case: Macros, code generation, DSL compilation"
