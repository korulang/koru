#!/bin/bash
# Verify: subflow dispatching ONLY pure events is transitively pure.
# Layer 2 positive case — mirrors 410_010's negative case.

if [ ! -f "backend.zig" ]; then
    echo "✗ backend.zig not found"
    exit 1
fi

# Confirm the compute proc has the expected pure flags (sanity check)
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
    echo "✓ compute proc: is_pure = true"
else
    echo "✗ FAIL: compute should be is_pure = true (~[pure])"
    exit 1
fi

if echo "$PROC" | grep -q 'is_transitively_pure = true'; then
    echo "✓ compute proc: is_transitively_pure = true"
else
    echo "✗ FAIL: compute should be is_transitively_pure = true"
    exit 1
fi

# Find the top-level subflow that dispatches compute
FLOW_LINE=$(grep -n '\.flow = Flow{' backend.zig | while read line; do
    linenum=$(echo "$line" | cut -d: -f1)
    if sed -n "$((linenum)),$((linenum + 10))p" backend.zig | grep -q '"compute"'; then
        echo "$linenum"
        break
    fi
done)

if [ -z "$FLOW_LINE" ]; then
    echo "✗ Could not find Flow dispatching compute"
    exit 1
fi

FLOW=$(sed -n "${FLOW_LINE},$((FLOW_LINE + 50))p" backend.zig)

if echo "$FLOW" | grep -q '.is_pure = true'; then
    echo "✓ subflow: is_pure = true (Layer 1 — composition is locally pure)"
else
    echo "✗ FAIL: subflow should be is_pure = true ALWAYS"
    exit 1
fi

if echo "$FLOW" | grep -q '.is_transitively_pure = true'; then
    echo "✓ subflow: is_transitively_pure = true (dispatches only into pure events)"
else
    echo "✗ FAIL: subflow should be is_transitively_pure = TRUE"
    echo "  It dispatches compute (pure) — transitive purity should propagate"
    exit 1
fi

echo ""
echo "✓ Subflow correctly marked transitively pure when dispatching only pure events"
exit 0
