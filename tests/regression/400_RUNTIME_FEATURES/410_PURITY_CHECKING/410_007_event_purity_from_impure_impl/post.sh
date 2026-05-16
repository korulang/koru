#!/bin/bash
# Verify: event with unannotated proc impl derives is_pure=false on
# the event declaration itself. Layer 2: event purity is computed
# from impl purity. Unannotated proc is structurally impure (Layer 1)
# and the event inherits that.

if [ ! -f "backend.zig" ]; then
    echo "✗ backend.zig not found"
    exit 1
fi

EVENT_LINE=$(grep -n 'event_decl = EventDecl' backend.zig | while read line; do
    linenum=$(echo "$line" | cut -d: -f1)
    if sed -n "$((linenum)),$((linenum + 5))p" backend.zig | grep -q '"log"'; then
        echo "$linenum"
        break
    fi
done)

if [ -z "$EVENT_LINE" ]; then
    echo "✗ Could not find log event_decl"
    exit 1
fi

EVENT=$(sed -n "$((EVENT_LINE)),$((EVENT_LINE + 40))p" backend.zig)

if echo "$EVENT" | grep -q 'is_pure = false'; then
    echo "✓ log event: is_pure = false (derived from unannotated proc impl)"
else
    echo "✗ FAIL: log event should be is_pure = false (derived from unannotated proc impl)"
    exit 1
fi

if echo "$EVENT" | grep -q 'is_transitively_pure = false'; then
    echo "✓ log event: is_transitively_pure = false (derived)"
else
    echo "✗ FAIL: log event should be is_transitively_pure = false"
    exit 1
fi

echo ""
echo "✓ Event correctly derives is_pure=false from its impure proc impl"
exit 0
