#!/bin/bash
# Benchmark: N-body gravitational simulation
# Compare Koru vs hand-written Zig/Rust/Go/C reference implementations
#
# This script compiles ALL reference implementations (C, Zig, Rust, Go, Koru)
# and compares them side-by-side using hyperfine.
#
# What we're testing:
# - Does Koru's event composition compile to code as fast as direct Zig?
# - How does Koru compare to Rust (zero-cost abstractions) and Go (GC)?
# - Is the gap Koru→Zig similar to Zig→C?
# - Does event-driven architecture have measurable overhead?

set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  N-Body Gravitational Simulation Benchmark"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Problem size (from NOTES.md: 50000 is the documented test size)
SIZE=5000000

# ============================================================================
# Compile ALL implementations
# ============================================================================

echo "📦 Compiling C reference (gcc -O3 -march=native)..."
gcc reference/reference.c -O3 -march=native -lm -o reference/nbody-c

echo "📦 Compiling Zig baseline (zig -O ReleaseFast)..."
zig build-exe reference/baseline.zig -O ReleaseFast -femit-bin=reference/nbody-zig

echo "📦 Compiling Rust baseline (rustc -C opt-level=3 -C target-cpu=native)..."
rustc -C opt-level=3 -C target-cpu=native reference/baseline.rs -o reference/nbody-rust
RUST_AVAILABLE=1

echo "📦 Compiling Go baseline (go build)..."
go build -o reference/nbody-go reference/baseline.go

echo "📦 Compiling Koru version (via regression runner)..."
# Use regression runner to compile (handles all 4 steps automatically)
cd /Users/larsde/src/koru
./run_regression.sh 2101_nbody > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "❌ ERROR: Koru compilation failed"
    echo "   Run './run_regression.sh 2101_nbody' to see errors"
    exit 1
fi
cd tests/regression/2100_LANGUAGE_SHOOTOUT/2101_nbody

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
./reference/nbody-rust $SIZE > actual-rust.txt 2>&1
./reference/nbody-go $SIZE > actual-go.txt 2>&1
./nbody-koru $SIZE > actual-koru.txt 2>&1

for lang in c zig rust go koru; do
    if ! diff -q expected_output.txt actual-$lang.txt > /dev/null 2>&1; then
        echo "❌ ERROR: $lang output doesn't match expected_output.txt"
        diff -u expected_output.txt actual-$lang.txt
        exit 1
    fi
done

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
    --command-name "Rust (opt-level=3)" "./reference/nbody-rust $SIZE" \
    --command-name "Zig (ReleaseFast)" "./reference/nbody-zig $SIZE" \
    --command-name "Koru → Zig" "./nbody-koru $SIZE" \
    --command-name "Go (default)" "./reference/nbody-go $SIZE"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Benchmark complete! Results saved to results.json"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "💡 Interpretation:"
echo "   - Expected order: C ≈ Rust > Koru ≈ Zig > Go"
echo "   - Compare Koru vs Zig: Is event abstraction zero-cost?"
echo "   - Compare Koru vs Rust: Does Koru match zero-cost abstractions?"
echo "   - Compare all vs Go: Where does GC overhead show up?"
echo "   - Compare Zig vs C: What's the baseline gap?"
echo ""
