#!/bin/bash
# Verify: event with [pure] proc impl derives is_pure=true on the
# event declaration itself. Layer 2: event purity is computed from
# impl purity (AND across impls).

if [ ! -f "backend.zig" ]; then
    echo "✗ backend.zig not found"
    exit 1
fi

# Find the event declaration for compute
EVENT_LINE=$(grep -n 'event_decl = EventDecl' backend.zig | while read line; do
    linenum=$(echo "$line" | cut -d: -f1)
    if sed -n "$((linenum)),$((linenum + 5))p" backend.zig | grep -q '"compute"'; then
        echo "$linenum"
        break
    fi
done)

if [ -z "$EVENT_LINE" ]; then
    echo "✗ Could not find compute event_decl"
    exit 1
fi

EVENT=$(sed -n "$((EVENT_LINE)),$((EVENT_LINE + 40))p" backend.zig)

if echo "$EVENT" | grep -q 'is_pure = true'; then
    echo "✓ compute event: is_pure = true (derived from pure proc impl)"
else
    echo "✗ FAIL: compute event should be is_pure = true (derived from ~[pure] proc impl)"
    exit 1
fi

if echo "$EVENT" | grep -q 'is_transitively_pure = true'; then
    echo "✓ compute event: is_transitively_pure = true (derived)"
else
    echo "✗ FAIL: compute event should be is_transitively_pure = true"
    exit 1
fi

echo ""
echo "✓ Event correctly derives is_pure=true from its pure proc impl"
exit 0
