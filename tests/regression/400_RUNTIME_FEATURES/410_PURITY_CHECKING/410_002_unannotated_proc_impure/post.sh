#!/bin/bash
# Verify: an unannotated proc is structurally impure (Layer 1 fact).
# is_pure=false and is_transitively_pure=false, no annotation involved.

if [ ! -f "backend.zig" ]; then
    echo "✗ backend.zig not found"
    exit 1
fi

PROC_LINE=$(grep -n 'proc_decl = ProcDecl' backend.zig | while read line; do
    linenum=$(echo "$line" | cut -d: -f1)
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
    echo "✓ log proc: is_pure = false (unannotated → structural default)"
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

echo ""
echo "✓ Unannotated proc correctly defaults to structurally impure"
exit 0
