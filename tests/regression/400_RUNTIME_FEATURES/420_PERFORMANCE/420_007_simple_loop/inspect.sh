#!/bin/bash
# Inspect what code was actually generated
# Compare Koru's label loops to Zig's while loops

echo "======================================"
echo "Generated Koru Code (output_emitted.zig)"
echo "======================================"
echo ""

if [ -f "output_emitted.zig" ]; then
    echo "Looking for loop patterns..."
    echo ""

    echo "1. Label-based loop (should look like: loop_x: while (true) { ... continue :loop_x; })"
    grep -A 10 "loop_.*: while" output_emitted.zig | head -15 || echo "  (not found - may use different pattern)"

    echo ""
    echo "2. Dead loop (should be eliminated or very simple)"
    grep -B 2 -A 5 "dead_loop\|dead.*while" output_emitted.zig | head -10 || echo "  ✅ Dead loop eliminated (not found in output)"

    echo ""
    echo "3. Main function"
    grep -A 20 "pub fn main" output_emitted.zig | head -25
else
    echo "❌ output_emitted.zig not found"
    echo "   Run: koruc input.kz"
fi

echo ""
echo "======================================"
echo "Baseline Zig Code"
echo "======================================"
echo ""
cat baseline.zig
