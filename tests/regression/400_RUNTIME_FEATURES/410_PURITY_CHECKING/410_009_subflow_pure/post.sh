#!/bin/bash
# Verify: Subflow calling pure proc should be transitively pure

if [ ! -f "backend.zig" ]; then
    echo "✗ backend.zig not found"
    exit 1
fi

# Check double proc - should be pure
# Get all lines around "double", find the proc_decl section
DOUBLE_LINE=$(grep -n 'proc_decl = ProcDecl' backend.zig | while read line; do
    linenum=$(echo "$line" | cut -d: -f1)
    # Check if "double" appears in next 5 lines
    if sed -n "$((linenum)),$((linenum + 5))p" backend.zig | grep -q '"double"'; then
        echo "$linenum"
        break
    fi
done)

if [ -z "$DOUBLE_LINE" ]; then
    echo "✗ Could not find double proc"
    exit 1
fi

# Get 15 lines from proc_decl to find purity fields
DOUBLE_PROC=$(sed -n "$((DOUBLE_LINE)),$((DOUBLE_LINE + 15))p" backend.zig)

if echo "$DOUBLE_PROC" | grep -q 'is_pure = true'; then
    echo "✓ double proc: is_pure = true"
else
    echo "✗ FAIL: double should be is_pure = true (marked ~[pure])"
    exit 1
fi

if echo "$DOUBLE_PROC" | grep -q 'is_transitively_pure = true'; then
    echo "✓ double proc: is_transitively_pure = true (calls nothing)"
else
    echo "✗ FAIL: double should be is_transitively_pure = true"
    exit 1
fi

# Check the top-level subflow - should be transitively pure
# Find the Flow structure that calls double (search for ".flow = Flow" to get top-level flows)
FLOW_LINE=$(grep -n '\.flow = Flow{' backend.zig | while read line; do
    linenum=$(echo "$line" | cut -d: -f1)
    # Check if "double" appears in next 10 lines
    if sed -n "$((linenum)),$((linenum + 10))p" backend.zig | grep -q '"double"'; then
        echo "$linenum"
        break
    fi
done)

if [ -z "$FLOW_LINE" ]; then
    echo "✗ Could not find Flow calling double"
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

# Subflow calls pure event, should be transitively pure
if echo "$FLOW" | grep -q '.is_transitively_pure = true'; then
    echo "✓ subflow: is_transitively_pure = true (calls only pure)"
else
    echo "✗ FAIL: subflow should be is_transitively_pure = true"
    echo "  It calls double (pure) - should propagate transitive purity"
    exit 1
fi

echo ""
echo "✓ Subflow correctly inherits transitive purity from pure proc"

exit 0
