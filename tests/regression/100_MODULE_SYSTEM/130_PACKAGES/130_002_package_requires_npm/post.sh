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

if echo "$AST_JSON" | grep -q '@korulang/gzip'; then
    echo "✓ Source parameter captured @korulang/gzip requirement in AST"
else
    echo "✗ Source parameter did NOT capture @korulang/gzip requirement"
    exit 1
fi

if echo "$AST_JSON" | grep -q '@korulang/sqlite3'; then
    echo "✓ Source parameter captured @korulang/sqlite3 requirement in AST"
else
    echo "✗ Source parameter did NOT capture @korulang/sqlite3 requirement"
    exit 1
fi

echo "✓ All three npm packages present in AST"

# Note: package.json generation will be tested once --install-packages flag is implemented
# For now, we just verify that:
# 1. The void event syntax works (compilation succeeds)
# 2. Source parameters are captured in AST

echo "✅ All validations passed!"
exit 0
