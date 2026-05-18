#!/bin/bash
# Verify: ~[pure] proc gets is_pure=true and is_transitively_pure=true.
# Layer 3 demonstration: annotation lifts the default impure assumption.

if [ ! -f "backend.zig" ]; then
    echo "✗ backend.zig not found"
    exit 1
fi

PROC_LINE=$(grep -n 'proc_decl = ProcDecl' backend.zig | while read line; do
    linenum=$(echo "$line" | cut -d: -f1)
    if sed -n "$((linenum)),$((linenum + 5))p" backend.zig | grep -q '"compute"'; then
        echo "$linenum"
        break
    fi
done)

if [ -z "$PROC_LINE" ]; then
    echo "✗ Could not find compute proc"
    exit 1
fi

PROC=$(sed -n "$((PROC_LINE)),$((PROC_LINE + 15))p" backend.zig)

if echo "$PROC" | grep -q 'is_pure = true'; then
    echo "✓ compute proc: is_pure = true (annotation lifted default)"
else
    echo "✗ FAIL: compute should be is_pure = true (has ~[pure] annotation)"
    exit 1
fi

if echo "$PROC" | grep -q 'is_transitively_pure = true'; then
    echo "✓ compute proc: is_transitively_pure = true (no calls, so trivially transitive)"
else
    echo "✗ FAIL: compute should be is_transitively_pure = true"
    exit 1
fi

echo ""
echo "✓ ~[pure] annotation correctly propagates to is_pure=true and is_transitively_pure=true"
exit 0
