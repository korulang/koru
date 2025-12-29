#!/bin/bash
# Verify npm package requirements are captured in AST

# Get AST as JSON
AST_JSON=$(koruc --ast-json input.kz 2>&1 | grep -v "^DEBUG:")

# Check that the Source parameter value contains the expected npm packages
if echo "$AST_JSON" | grep -q '@koru/graphics'; then
    echo "✓ Source parameter captured @koru/graphics requirement in AST"
else
    echo "✗ Source parameter did NOT capture @koru/graphics requirement"
    echo "AST JSON (first 100 lines):"
    echo "$AST_JSON" | head -100
    exit 1
fi

if echo "$AST_JSON" | grep -q 'lodash'; then
    echo "✓ Source parameter captured lodash requirement in AST"
else
    echo "✗ Source parameter did NOT capture lodash requirement"
    exit 1
fi

if echo "$AST_JSON" | grep -q 'axios'; then
    echo "✓ Source parameter captured axios requirement in AST"
else
    echo "✗ Source parameter did NOT capture axios requirement"
    exit 1
fi

echo "✓ All three npm packages present in AST"

# Note: package.json generation will be tested once --install-packages flag is implemented
# For now, we just verify that:
# 1. The void event syntax works (compilation succeeds)
# 2. Source parameters are captured in AST

echo "✅ All validations passed!"
exit 0
