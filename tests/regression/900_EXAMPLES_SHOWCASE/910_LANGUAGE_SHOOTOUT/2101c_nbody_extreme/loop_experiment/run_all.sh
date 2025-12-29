#!/bin/bash

echo "Building and running all versions..."
echo ""

echo "=== Version 1: Handler call ==="
zig build-exe version1_handler_call.zig -O ReleaseFast -femit-bin=v1
./v1
echo ""

echo "=== Version 2: Inlined handler ==="
zig build-exe version2_inlined_handler.zig -O ReleaseFast -femit-bin=v2
./v2
echo ""

echo "=== Version 3: Simple while ==="
zig build-exe version3_simple_while.zig -O ReleaseFast -femit-bin=v3
./v3
echo ""

echo "=== Version 4: while(true) + break ==="
zig build-exe version4_while_true_break.zig -O ReleaseFast -femit-bin=v4
./v4
echo ""

echo "=== Comparison ==="
echo "If Version 2 ≈ Version 3/4: Inlining solves the problem!"
echo "If Version 2 is still slow: Union construction is the bottleneck"
echo "If Version 3 ≈ Version 4: Both loop patterns are equivalent"
