#!/bin/bash
# Benchmark: N-body gravitational simulation
# Compare Koru vs hand-written Zig vs C reference
#
# This script compiles ALL reference implementations (C, Zig, Koru)
# and compares them side-by-side using hyperfine.
#
# What we're testing:
# - Does Koru's event composition compile to code as fast as direct Zig?
# - Is the gap Koru→Zig similar to Zig→C?
# - Does event-driven architecture have measurable overhead?

set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  N-Body Gravitational Simulation Benchmark"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Problem size (from SPEC: 50000 for CI, 5000000 for manual testing)
SIZE=50000

# ============================================================================
# Compile ALL implementations
# ============================================================================

echo "📦 Compiling C reference (gcc -O3 -march=native)..."
gcc reference/reference.c -O3 -march=native -lm -o reference/nbody-c

echo "📦 Compiling Zig baseline (zig -O ReleaseFast)..."
zig build-exe reference/baseline.zig -O ReleaseFast -femit-bin=reference/nbody-zig

echo "📦 Compiling Koru version (via regression runner)..."
# Use regression runner to compile (handles all 4 steps automatically)
cd /Users/larsde/src/koru
./run_regression.sh 2101b_nbody_granular > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "❌ ERROR: Koru compilation failed"
    echo "   Run './run_regression.sh 2101b_nbody_granular' to see errors"
    exit 1
fi
cd tests/regression/2100_LANGUAGE_SHOOTOUT/2101b_nbody_granular

# Copy the compiled binary
if [ -f "output" ]; then
    cp output nbody-koru
    chmod +x nbody-koru
else
    echo "❌ ERROR: Regression runner didn't produce 'output' binary"
    exit 1
fi

echo ""
echo "✅ All implementations compiled successfully"
echo ""

# ============================================================================
# Verify correctness before benchmarking
# ============================================================================

echo "🔍 Verifying correctness (output must match expected_output.txt)..."

./reference/nbody-c $SIZE > actual-c.txt
./reference/nbody-zig $SIZE > actual-zig.txt 2>&1
./nbody-koru $SIZE > actual-koru.txt 2>&1

if ! diff -q expected_output.txt actual-c.txt > /dev/null 2>&1; then
    echo "❌ ERROR: C reference output doesn't match expected_output.txt"
    diff -u expected_output.txt actual-c.txt
    exit 1
fi

if ! diff -q expected_output.txt actual-zig.txt > /dev/null 2>&1; then
    echo "❌ ERROR: Zig baseline output doesn't match expected_output.txt"
    diff -u expected_output.txt actual-zig.txt
    exit 1
fi

if ! diff -q expected_output.txt actual-koru.txt > /dev/null 2>&1; then
    echo "❌ ERROR: Koru output doesn't match expected_output.txt"
    diff -u expected_output.txt actual-koru.txt
    exit 1
fi

echo "✅ All outputs match expected_output.txt"
echo ""

# ============================================================================
# Run performance benchmark
# ============================================================================

echo "🏃 Running performance benchmark with hyperfine..."
echo "   Problem size: N=$SIZE"
echo "   Warmup runs: 3"
echo "   Benchmark runs: 10"
echo ""

# Check if hyperfine is installed
if ! command -v hyperfine &> /dev/null; then
    echo "⚠️  hyperfine not installed"
    echo "   Install with: brew install hyperfine (macOS) or cargo install hyperfine"
    echo "   Skipping performance benchmark..."
    exit 0
fi

# Run benchmark comparing ALL implementations
hyperfine \
    --warmup 3 \
    --min-runs 10 \
    --export-json results.json \
    --style full \
    --command-name "C (gcc -O3)" "./reference/nbody-c $SIZE" \
    --command-name "Zig (ReleaseFast)" "./reference/nbody-zig $SIZE" \
    --command-name "Koru → Zig" "./nbody-koru $SIZE"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Benchmark complete! Results saved to results.json"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "💡 Interpretation:"
echo "   - Compare Koru vs Zig: Is event abstraction zero-cost?"
echo "   - Compare Zig vs C: What's the baseline gap?"
echo "   - Is Koru's overhead similar to Zig's overhead?"
echo ""
