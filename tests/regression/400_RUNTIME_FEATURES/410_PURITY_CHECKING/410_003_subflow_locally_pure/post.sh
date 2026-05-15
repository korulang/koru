#!/bin/bash
# Verify: subflow is_pure = true ALWAYS (Layer 1 structural fact).
# Composition has no body execution, so locally pure regardless
# of what it dispatches.

if [ ! -f "backend.zig" ]; then
    echo "✗ backend.zig not found"
    exit 1
fi

# Find any top-level Flow declaration
FLOW_LINE=$(grep -n '\.flow = Flow{' backend.zig | head -1 | cut -d: -f1)

if [ -z "$FLOW_LINE" ]; then
    echo "✗ Could not find Flow declaration"
    exit 1
fi

FLOW=$(sed -n "${FLOW_LINE},$((FLOW_LINE + 50))p" backend.zig)

if echo "$FLOW" | grep -q '.is_pure = true'; then
    echo "✓ subflow: is_pure = true (Layer 1 structural fact — composition is always locally pure)"
else
    echo "✗ FAIL: subflow should be is_pure = true ALWAYS"
    exit 1
fi

echo ""
echo "✓ Subflow correctly marked locally pure regardless of dispatch contents"
exit 0
