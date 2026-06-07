#!/bin/bash
# Verify: subflow is_pure = true ALWAYS (Layer 1 structural fact).
# Composition has no body execution, so locally pure regardless
# of what it dispatches.

if [ ! -f "backend.zig" ]; then
    echo "✗ backend.zig not found"
    exit 1
fi

# AST literal moved from backend.zig to program_ast.zig (split landed 2026-05-20).
# Concatenate both so grep -n / sed -n by line number still work.
cat backend.zig program_ast.zig 2>/dev/null > _combined_emit.zig

# Find any top-level Flow declaration
FLOW_LINE=$(grep -n '\.flow = Flow{' _combined_emit.zig | head -1 | cut -d: -f1)

if [ -z "$FLOW_LINE" ]; then
    echo "✗ Could not find Flow declaration"
    exit 1
fi

FLOW=$(sed -n "${FLOW_LINE},$((FLOW_LINE + 50))p" _combined_emit.zig)

if echo "$FLOW" | grep -q '.is_pure = true'; then
    echo "✓ subflow: is_pure = true (Layer 1 structural fact — composition is always locally pure)"
else
    echo "✗ FAIL: subflow should be is_pure = true ALWAYS"
    exit 1
fi

echo ""
echo "✓ Subflow correctly marked locally pure regardless of dispatch contents"
exit 0
