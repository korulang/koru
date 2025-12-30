#!/bin/bash
# Benchmark: N-body Pure Subflow Version
# Compare Koru pure subflows vs hand-written Zig/Rust/C/Go
#
# This tests the SUBFLOW implementation - no ~proc except for I/O.
# The interesting comparison is Koru vs Zig: are the abstractions zero-cost?

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REF_DIR="$SCRIPT_DIR/../2101_nbody/reference"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  N-Body: Pure Subflow Benchmark"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

SIZE=${1:-50000000}
echo "Problem size: $SIZE iterations"
echo ""

# ============================================================================
# Build reference implementations if needed
# ============================================================================

# Use forloop version - while loops are significantly slower in Zig
if [ ! -f "$REF_DIR/nbody-zig-forloop" ]; then
    echo "📦 Building Zig reference (forloop)..."
    zig build-exe "$REF_DIR/baseline_forloop.zig" -O ReleaseFast -femit-bin="$REF_DIR/nbody-zig-forloop"
fi

if [ ! -f "$REF_DIR/nbody-rust" ]; then
    echo "📦 Building Rust reference..."
    rustc -C opt-level=3 -C target-cpu=native "$REF_DIR/baseline.rs" -o "$REF_DIR/nbody-rust"
fi

if [ ! -f "$REF_DIR/nbody-c" ]; then
    echo "📦 Building C reference..."
    gcc "$REF_DIR/reference.c" -O3 -march=native -lm -o "$REF_DIR/nbody-c"
fi

if [ ! -f "$REF_DIR/nbody-go" ]; then
    echo "📦 Building Go reference..."
    go build -o "$REF_DIR/nbody-go" "$REF_DIR/baseline.go"
fi

# ============================================================================
# Build Koru subflow version
# ============================================================================

echo "📦 Building Koru pure subflow version..."
cd /Users/larsde/src/koru
./run_regression.sh 2101g_nbody_subflow > /dev/null 2>&1 || true
cd "$SCRIPT_DIR"

if [ ! -f "output" ]; then
    echo "❌ Koru build failed. Run manually to see errors:"
    echo "   ./run_regression.sh 2101g_nbody_subflow"
    exit 1
fi

echo "✅ All builds ready"
echo ""

# ============================================================================
# Quick correctness check
# ============================================================================

echo "🔍 Verifying correctness..."
EXPECTED="-0.169075164"

KORU_OUT=$("$SCRIPT_DIR/output" 1000 2>&1 | head -1)
ZIG_OUT=$("$REF_DIR/nbody-zig-forloop" 1000 2>&1 | head -1)

if [[ "$KORU_OUT" != "$EXPECTED"* ]] || [[ "$ZIG_OUT" != "$EXPECTED"* ]]; then
    echo "❌ Output mismatch!"
    echo "   Koru: $KORU_OUT"
    echo "   Zig:  $ZIG_OUT"
    echo "   Expected prefix: $EXPECTED"
    exit 1
fi
echo "✅ Outputs match"
echo ""

# ============================================================================
# Run benchmark
# ============================================================================

echo "🏃 Running benchmark (this takes a while)..."
echo ""

if ! command -v hyperfine &> /dev/null; then
    echo "hyperfine not found. Running manual timing..."
    echo ""

    echo "Zig (hand-written, forloop):"
    time "$REF_DIR/nbody-zig-forloop" $SIZE
    echo ""

    echo "Koru (pure subflows):"
    time "$SCRIPT_DIR/output" $SIZE
    echo ""

    echo "Rust:"
    time "$REF_DIR/nbody-rust" $SIZE
    echo ""

    exit 0
fi

# Full hyperfine benchmark
hyperfine \
    --warmup 2 \
    --min-runs 5 \
    --style full \
    --command-name "Zig (hand-written)" "$REF_DIR/nbody-zig-forloop $SIZE" \
    --command-name "Koru (pure subflows)" "$SCRIPT_DIR/output $SIZE" \
    --command-name "Rust" "$REF_DIR/nbody-rust $SIZE" \
    --command-name "C (gcc -O3)" "$REF_DIR/nbody-c $SIZE" \
    --command-name "Go" "$REF_DIR/nbody-go $SIZE"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Key comparison: Zig vs Koru"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "If Zig ≈ Koru (within noise): Zero-cost abstractions CONFIRMED"
echo "Rust being faster is expected (different LLVM backend tuning)"
echo "Go being slower is expected (GC overhead)"
echo ""
