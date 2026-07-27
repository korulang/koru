#!/bin/bash
# Post-validation: Verify AST dumps at both stages
# The ast_dump event runs during backend execution, output goes to backend.err

set -e

if [ ! -f "backend.err" ]; then
    echo "❌ FAIL: No backend.err file found"
    exit 1
fi

# Check for post-elaborate dump
if ! grep -q "=== AST DUMP: post-elaborate ===" backend.err; then
    echo "❌ Missing post-elaborate AST dump"
    exit 1
fi
echo "✅ Post-elaborate AST dump found"

# Check for post-analysis dump
if ! grep -q "=== AST DUMP: post-analysis ===" backend.err; then
    echo "❌ Missing post-analysis AST dump"
    exit 1
fi
echo "✅ Post-analysis AST dump found"

# Verify dumps contain JSON (have opening brace after header)
if ! grep -A1 "post-elaborate" backend.err | grep -q "{"; then
    echo "❌ Post-elaborate dump doesn't look like JSON"
    exit 1
fi

if ! grep -A1 "post-analysis" backend.err | grep -q "{"; then
    echo "❌ Post-analysis dump doesn't look like JSON"
    exit 1
fi

echo ""
echo "🎉 AST dumps at multiple pipeline stages working!"
echo "   You can now introspect the compiler at any point."
exit 0
