#!/bin/bash
# Verify: subflow dispatching ONLY pure events is transitively pure.
# Layer 2 positive case — mirrors 410_010's negative case.

if [ ! -f "backend.zig" ]; then
    echo "✗ backend.zig not found"
    exit 1
fi

# AST literal moved from backend.zig to program_ast.zig (split landed 2026-05-20).
# Concatenate both so grep -n / sed -n by line number still work.
cat backend.zig program_ast.zig 2>/dev/null > _combined_emit.zig

# Confirm the compute proc has the expected pure flags (sanity check)
PROC_LINE=$(grep -n 'proc_decl = ProcDecl' _combined_emit.zig | while read line; do
    linenum=$(echo "$line" | cut -d: -f1)
    if sed -n "$((linenum)),$((linenum + 5))p" _combined_emit.zig | grep -q '"compute"'; then
        echo "$linenum"
        break
    fi
done)

if [ -z "$PROC_LINE" ]; then
    echo "✗ Could not find compute proc"
    exit 1
fi

# The ProcDecl block now spans more lines (body is a Source literal: text +
# location + scope + phantom_type). Bound the block at its own `.module =` field
# rather than a fixed window — robust to body length, and won't bleed into a
# neighbouring proc (which would falsely match is_pure on negative tests).
PROC_END=$(awk -v s="$PROC_LINE" 'NR>s && /\.module = /{print NR; exit}' _combined_emit.zig)
PROC=$(sed -n "$((PROC_LINE)),$((PROC_END))p" _combined_emit.zig)

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
FLOW_LINE=$(grep -n '\.flow = Flow{' _combined_emit.zig | while read line; do
    linenum=$(echo "$line" | cut -d: -f1)
    if sed -n "$((linenum)),$((linenum + 10))p" _combined_emit.zig | grep -q '"compute"'; then
        echo "$linenum"
        break
    fi
done)

if [ -z "$FLOW_LINE" ]; then
    echo "✗ Could not find Flow dispatching compute"
    exit 1
fi

FLOW=$(sed -n "${FLOW_LINE},$((FLOW_LINE + 50))p" _combined_emit.zig)

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
