#!/bin/bash
# Koru Language Shootout Benchmark Script
# Usage: ./benchmark.sh [runs] [iterations]
#   runs: number of hyperfine runs (default: 20)
#   iterations: n-body iterations (default: 50000000)

RUNS=${1:-20}
ITERS=${2:-50000000}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Koru Language Shootout Benchmark ==="
echo "Runs: $RUNS, Iterations: $ITERS"
echo ""

# Check binaries exist
KORU_BIN="$SCRIPT_DIR/2101g_nbody_subflow/a.out"
ZIG_BIN="$SCRIPT_DIR/2101_nbody_optimized/reference/nbody-zig-for"
RUST_BIN="$SCRIPT_DIR/2101_nbody_optimized/reference/nbody-rust"
C_BIN="$SCRIPT_DIR/2101_nbody_optimized/reference/nbody-c"

missing=""
[ ! -x "$KORU_BIN" ] && missing="$missing Koru($KORU_BIN)"
[ ! -x "$ZIG_BIN" ] && missing="$missing Zig($ZIG_BIN)"
[ ! -x "$RUST_BIN" ] && missing="$missing Rust($RUST_BIN)"

if [ -n "$missing" ]; then
    echo "ERROR: Missing binaries:$missing"
    echo ""
    echo "Build Koru: cd 2101g_nbody_subflow && zig build run -- build input.kz"
    echo "Build Zig:  cd 2101_nbody_optimized/reference && zig build-exe baseline.zig -O ReleaseFast -femit-bin=nbody-zig-for"
    exit 1
fi

# Verify outputs match
echo "Verifying correctness (1000 iterations)..."
KORU_OUT=$("$KORU_BIN" 1000 2>&1)
ZIG_OUT=$("$ZIG_BIN" 1000 2>&1)
RUST_OUT=$("$RUST_BIN" 1000 2>&1)

if [ "$KORU_OUT" != "$ZIG_OUT" ] || [ "$KORU_OUT" != "$RUST_OUT" ]; then
    echo "ERROR: Outputs don't match!"
    echo "Koru: $KORU_OUT"
    echo "Zig:  $ZIG_OUT"
    echo "Rust: $RUST_OUT"
    exit 1
fi
echo "All outputs match: $KORU_OUT"
echo ""

# Run benchmark
echo "Running hyperfine benchmark..."
echo ""

# Check if we can clear caches (requires sudo)
if sudo -n true 2>/dev/null; then
    echo "(Running with cache clearing)"
    hyperfine \
        --warmup 3 \
        --runs "$RUNS" \
        --prepare 'sync; sudo purge 2>/dev/null || sudo sh -c "echo 3 > /proc/sys/vm/drop_caches" 2>/dev/null || true' \
        --export-markdown "/tmp/koru_bench_${ITERS}.md" \
        --export-json "/tmp/koru_bench_${ITERS}.json" \
        -n "Koru (subflow)" "$KORU_BIN $ITERS" \
        -n "Zig (for loops)" "$ZIG_BIN $ITERS" \
        -n "Rust" "$RUST_BIN $ITERS"
else
    echo "(Running without cache clearing - run with sudo for cleaner results)"
    hyperfine \
        --warmup 3 \
        --runs "$RUNS" \
        --export-markdown "/tmp/koru_bench_${ITERS}.md" \
        --export-json "/tmp/koru_bench_${ITERS}.json" \
        -n "Koru (subflow)" "$KORU_BIN $ITERS" \
        -n "Zig (for loops)" "$ZIG_BIN $ITERS" \
        -n "Rust" "$RUST_BIN $ITERS"
fi

echo ""
echo "Results saved to:"
echo "  Markdown: /tmp/koru_bench_${ITERS}.md"
echo "  JSON:     /tmp/koru_bench_${ITERS}.json"
echo ""
cat "/tmp/koru_bench_${ITERS}.md"
