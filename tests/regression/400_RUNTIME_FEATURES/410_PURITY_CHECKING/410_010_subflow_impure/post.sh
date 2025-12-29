#!/bin/bash
# Verify: Subflow calling impure proc should be transitively IMPURE

if [ ! -f "backend.zig" ]; then
    echo "✗ backend.zig not found"
    exit 1
fi

# Check log proc - should be IMPURE (not marked ~[pure])
PROC_LINE=$(grep -n 'proc_decl = ProcDecl' backend.zig | while read line; do
    linenum=$(echo "$line" | cut -d: -f1)
    # Check if "log" appears in next 5 lines
    if sed -n "$((linenum)),$((linenum + 5))p" backend.zig | grep -q '"log"'; then
        echo "$linenum"
        break
    fi
done)

if [ -z "$PROC_LINE" ]; then
    echo "✗ Could not find log proc"
    exit 1
fi

PROC=$(sed -n "$((PROC_LINE)),$((PROC_LINE + 15))p" backend.zig)

if echo "$PROC" | grep -q 'is_pure = false'; then
    echo "✓ log proc: is_pure = false (unmarked, defaults to impure)"
else
    echo "✗ FAIL: log should be is_pure = false (no ~[pure] annotation)"
    exit 1
fi

if echo "$PROC" | grep -q 'is_transitively_pure = false'; then
    echo "✓ log proc: is_transitively_pure = false"
else
    echo "✗ FAIL: log should be is_transitively_pure = false"
    exit 1
fi

# Check the top-level subflow - should be transitively IMPURE
FLOW_LINE=$(grep -n '\.flow = Flow{' backend.zig | while read line; do
    linenum=$(echo "$line" | cut -d: -f1)
    # Check if "log" appears in next 10 lines
    if sed -n "$((linenum)),$((linenum + 10))p" backend.zig | grep -q '"log"'; then
        echo "$linenum"
        break
    fi
done)

if [ -z "$FLOW_LINE" ]; then
    echo "✗ Could not find Flow calling log"
    exit 1
fi

FLOW=$(sed -n "${FLOW_LINE},$((FLOW_LINE + 50))p" backend.zig)

# Flows are always locally pure
if echo "$FLOW" | grep -q '.is_pure = true'; then
    echo "✓ subflow: is_pure = true (flows are always locally pure)"
else
    echo "✗ FAIL: subflow should be is_pure = true"
    exit 1
fi

# Subflow calls impure event, should be transitively IMPURE
if echo "$FLOW" | grep -q '.is_transitively_pure = false'; then
    echo "✓ subflow: is_transitively_pure = false (calls impure log)"
else
    echo "✗ FAIL: subflow should be is_transitively_pure = FALSE"
    echo "  It calls log (impure) - should NOT propagate transitive purity"
    exit 1
fi

echo ""
echo "✓ Subflow correctly marked transitively impure when calling impure proc"

exit 0
