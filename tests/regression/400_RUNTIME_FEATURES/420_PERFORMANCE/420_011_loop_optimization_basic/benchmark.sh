#!/bin/bash
# Benchmark: Loop Optimization - Basic Checker Event Pattern
# Compare multiple optimization levels to isolate performance impact

set -e

echo "Building all versions..."

echo "  1. Baseline (native for loop)..."
zig build-exe baseline.zig -O ReleaseFast -femit-bin=baseline

echo "  2. Koru current (from compiler)..."
if [ -f "output_emitted.zig" ]; then
    zig build-exe output_emitted.zig -O ReleaseFast -femit-bin=koru_current
elif [ -f "output" ]; then
    cp output koru_current
    chmod +x koru_current
else
    echo "ERROR: No Koru output found (output_emitted.zig or output)"
    exit 1
fi

echo "  3. HandOpt1 (remove dead unpacking)..."
zig build-exe handopt1.zig -O ReleaseFast -femit-bin=handopt1

echo "  4. HandOpt2 (inline handler body)..."
zig build-exe handopt2.zig -O ReleaseFast -femit-bin=handopt2

echo "  5. HandOpt3 (native for loop)..."
zig build-exe handopt3.zig -O ReleaseFast -femit-bin=handopt3

echo ""
echo "Running benchmarks with hyperfine..."

# Check if hyperfine is installed
if ! command -v hyperfine &> /dev/null; then
    echo "ERROR: hyperfine not installed"
    echo "Install with: brew install hyperfine (macOS) or cargo install hyperfine"
    exit 1
fi

# Run benchmark comparing all versions
hyperfine --warmup 5 --runs 30 --shell=none \
    --export-json results.json \
    --command-name "1. Baseline (for loop)" './baseline' \
    --command-name "2. Koru Current" './koru_current' \
    --command-name "3. HandOpt1 (no dead code)" './handopt1' \
    --command-name "4. HandOpt2 (inline handler)" './handopt2' \
    --command-name "5. HandOpt3 (for loop)" './handopt3'

echo ""
echo "Benchmark complete! Results saved to results.json"
echo ""
echo "Analysis:"
echo "  Baseline vs Koru:     Shows total gap"
echo "  Koru vs HandOpt1:     Dead code removal impact"
echo "  HandOpt1 vs HandOpt2: Handler inlining impact"
echo "  HandOpt2 vs HandOpt3: Loop form impact (while vs for)"
