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
echo "  C vs Zig vs Go vs Rust vs Koru"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Problem size (from SPEC: 50000 for CI, 5000000 for manual testing)
SIZE=5000000

# ============================================================================
# Compile ALL implementations
# ============================================================================

echo "📦 Compiling C reference (gcc -O3 -march=native)..."
gcc reference/reference.c -O3 -march=native -lm -o reference/nbody-c

echo "📦 Compiling Zig baseline (zig -O ReleaseFast)..."
zig build-exe reference/baseline.zig -O ReleaseFast -femit-bin=reference/nbody-zig

echo "📦 Compiling Go baseline (go build -ldflags='-s -w')..."
go build -ldflags='-s -w' -o reference/nbody-go reference/baseline.go

echo "📦 Compiling Rust baseline (rustc -C opt-level=3 -C target-cpu=native)..."
rustc -C opt-level=3 -C target-cpu=native -o reference/nbody-rust reference/baseline.rs

echo "📦 Compiling Koru hand-optimized (zig -O ReleaseFast)..."
zig build-exe reference/koru-handopt.zig -O ReleaseFast -femit-bin=reference/nbody-koru-handopt

echo "📦 Compiling Koru version (via regression runner)..."
# Use regression runner to compile (handles all 4 steps automatically)
cd /Users/larsde/src/koru
./run_regression.sh 2101c_nbody_extreme > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "❌ ERROR: Koru compilation failed"
    echo "   Run './run_regression.sh 2101c_nbody_extreme' to see errors"
    exit 1
fi
cd tests/regression/2100_LANGUAGE_SHOOTOUT/2101c_nbody_extreme

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
./reference/nbody-go $SIZE > actual-go.txt 2>&1
./reference/nbody-rust $SIZE > actual-rust.txt 2>&1
./nbody-koru $SIZE > actual-koru.txt 2>&1
./reference/nbody-koru-handopt $SIZE > actual-koru-handopt.txt 2>&1

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

if ! diff -q expected_output.txt actual-go.txt > /dev/null 2>&1; then
    echo "❌ ERROR: Go baseline output doesn't match expected_output.txt"
    diff -u expected_output.txt actual-go.txt
    exit 1
fi

if ! diff -q expected_output.txt actual-rust.txt > /dev/null 2>&1; then
    echo "❌ ERROR: Rust baseline output doesn't match expected_output.txt"
    diff -u expected_output.txt actual-rust.txt
    exit 1
fi

if ! diff -q expected_output.txt actual-koru.txt > /dev/null 2>&1; then
    echo "❌ ERROR: Koru output doesn't match expected_output.txt"
    diff -u expected_output.txt actual-koru.txt
    exit 1
fi

if ! diff -q expected_output.txt actual-koru-handopt.txt > /dev/null 2>&1; then
    echo "❌ ERROR: Koru hand-optimized output doesn't match expected_output.txt"
    diff -u expected_output.txt actual-koru-handopt.txt
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
    --command-name "Go (optimized)" "./reference/nbody-go $SIZE" \
    --command-name "Rust (opt-level=3)" "./reference/nbody-rust $SIZE" \
    --command-name "Koru → Zig" "./nbody-koru $SIZE" \
    --command-name "Koru (hand-optimized)" "./reference/nbody-koru-handopt $SIZE"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Benchmark complete! Results saved to results.json"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "💡 Interpretation:"
echo "   - C: Fastest compiled baseline (gcc -O3)"
echo "   - Zig: Zero-cost abstractions (ReleaseFast)"
echo "   - Go: GC overhead visible in numeric workloads"
echo "   - Rust: Should match C performance (zero-cost abstractions)"
echo "   - Koru → Zig: Event-driven recursive pattern (original)"
echo "   - Koru (hand-optimized): Native for loops + inlined body (AST optimization prototype)"
echo ""
