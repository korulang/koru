#!/bin/bash
# Benchmark: Loop Optimization - Basic Checker Event Pattern
# Compare Koru optimized loop vs hand-written Zig for loop

set -e

echo "Building baseline (Zig)..."
zig build-exe baseline.zig -O ReleaseFast

echo "Building Koru version..."
# Assuming output_emitted.zig or output exists from test runner
if [ -f "output_emitted.zig" ]; then
    zig build-exe output_emitted.zig -O ReleaseFast -femit-bin=koru_output
elif [ -f "output" ]; then
    # Already compiled, copy it
    cp output koru_output
    chmod +x koru_output
else
    echo "ERROR: No Koru output found (output_emitted.zig or output)"
    exit 1
fi

echo ""
echo "Running benchmarks with hyperfine..."

# Check if hyperfine is installed
if ! command -v hyperfine &> /dev/null; then
    echo "ERROR: hyperfine not installed"
    echo "Install with: brew install hyperfine (macOS) or cargo install hyperfine"
    exit 1
fi

# Run benchmark
# Use --shell=none to avoid shell startup overhead
# Use more runs for better statistics on fast benchmarks
hyperfine --warmup 5 --runs 30 --shell=none \
    --export-json results.json \
    --command-name "Baseline (Zig)" './baseline' \
    --command-name "Koru (Optimized)" './koru_output'

echo ""
echo "Benchmark complete! Results saved to results.json"
