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
KORU_BIN="$SCRIPT_DIR/2101g_nbody_kernel_pairwise/a.out"
ZIG_OPT_BIN="$SCRIPT_DIR/2101_nbody_optimized/reference/nbody-zig-opt"
ZIG_NAIVE_BIN="$SCRIPT_DIR/2101_nbody/reference/nbody-zig-naive"
RUST_BIN="$SCRIPT_DIR/2101_nbody_optimized/reference/nbody-rust"
C_BIN="$SCRIPT_DIR/2101_nbody_optimized/reference/nbody-c"

missing=""
[ ! -x "$KORU_BIN" ] && missing="$missing Koru($KORU_BIN)"
[ ! -x "$ZIG_OPT_BIN" ] && missing="$missing Zig-opt($ZIG_OPT_BIN)"
[ ! -x "$ZIG_NAIVE_BIN" ] && missing="$missing Zig-naive($ZIG_NAIVE_BIN)"
[ ! -x "$RUST_BIN" ] && missing="$missing Rust($RUST_BIN)"
[ ! -x "$C_BIN" ] && missing="$missing C($C_BIN)"

if [ -n "$missing" ]; then
    echo "ERROR: Missing binaries:$missing"
    echo ""
    echo "Build commands:"
    echo "  Koru:        cd 2101g_nbody_kernel_pairwise && zig build-exe output_emitted.zig -O ReleaseFast -femit-bin=a.out"
    echo "  Zig (opt):   cd 2101_nbody_optimized/reference && zig build-exe baseline.zig -O ReleaseFast -femit-bin=nbody-zig-opt"
    echo "  Zig (naive): cd 2101_nbody/reference && zig build-exe baseline.zig -O ReleaseFast -femit-bin=nbody-zig-naive"
    echo "  Rust:        cd 2101_nbody_optimized/reference && rustc -C opt-level=3 -C target-cpu=native -o nbody-rust baseline.rs"
    echo "  C:           cd 2101_nbody_optimized/reference && clang -O3 -ffast-math -fomit-frame-pointer -march=native reference.c -lm -o nbody-c"
    exit 1
fi

# Verify outputs match
echo "Verifying correctness (1000 iterations)..."
KORU_OUT=$("$KORU_BIN" 1000 2>&1)
ZIG_OPT_OUT=$("$ZIG_OPT_BIN" 1000 2>&1)
ZIG_NAIVE_OUT=$("$ZIG_NAIVE_BIN" 1000 2>&1)
RUST_OUT=$("$RUST_BIN" 1000 2>&1)
C_OUT=$("$C_BIN" 1000 2>&1)

if [ "$KORU_OUT" != "$ZIG_OPT_OUT" ] || [ "$KORU_OUT" != "$ZIG_NAIVE_OUT" ] || [ "$KORU_OUT" != "$RUST_OUT" ] || [ "$KORU_OUT" != "$C_OUT" ]; then
    echo "ERROR: Outputs don't match!"
    echo "Koru:        $KORU_OUT"
    echo "Zig (opt):   $ZIG_OPT_OUT"
    echo "Zig (naive): $ZIG_NAIVE_OUT"
    echo "Rust:        $RUST_OUT"
    echo "C:           $C_OUT"
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
        -n "Koru" "$KORU_BIN $ITERS" \
        -n "Zig (optimized)" "$ZIG_OPT_BIN $ITERS" \
        -n "Zig (idiomatic)" "$ZIG_NAIVE_BIN $ITERS" \
        -n "Rust" "$RUST_BIN $ITERS" \
        -n "C" "$C_BIN $ITERS"
else
    echo "(Running without cache clearing - run with sudo for cleaner results)"
    hyperfine \
        --warmup 3 \
        --runs "$RUNS" \
        --export-markdown "/tmp/koru_bench_${ITERS}.md" \
        --export-json "/tmp/koru_bench_${ITERS}.json" \
        -n "Koru" "$KORU_BIN $ITERS" \
        -n "Zig (optimized)" "$ZIG_OPT_BIN $ITERS" \
        -n "Zig (idiomatic)" "$ZIG_NAIVE_BIN $ITERS" \
        -n "Rust" "$RUST_BIN $ITERS" \
        -n "C" "$C_BIN $ITERS"
fi

echo ""
echo "Results saved to:"
echo "  Markdown: /tmp/koru_bench_${ITERS}.md"
echo "  JSON:     /tmp/koru_bench_${ITERS}.json"
echo ""
cat "/tmp/koru_bench_${ITERS}.md"
