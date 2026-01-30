#!/bin/bash
# N-body benchmark runner
# Usage: ./run.sh [iterations] [runs]
#   iterations: simulation iterations (default: 50000000)
#   runs: hyperfine runs (default: 10)

set -e
cd "$(dirname "$0")"

ITERS=${1:-50000000}
RUNS=${2:-10}

echo "=== N-body Benchmark ==="
echo "Iterations: $ITERS"
echo "Hyperfine runs: $RUNS"
echo ""

# --- Build everything ---
echo "Building..."

# Koru implementations - build from archived test directories
# Step 1: Generate code (zig build runs the compiler backend)
# Step 2: Compile the generated output_emitted.zig to a binary
echo "  Koru kernel_pairwise..."
(cd ../_archive/2101g_nbody_kernel_pairwise && zig build -Doptimize=ReleaseFast 2>/dev/null)
zig build-exe ../_archive/2101g_nbody_kernel_pairwise/output_emitted.zig -O ReleaseFast -fno-emit-bin -femit-bin=bin/koru-kernel-pairwise 2>/dev/null

echo "  Koru arrayed_capture..."
(cd ../_archive/2101f_nbody_arrayed_capture && zig build -Doptimize=ReleaseFast 2>/dev/null)
zig build-exe ../_archive/2101f_nbody_arrayed_capture/output_emitted.zig -O ReleaseFast -fno-emit-bin -femit-bin=bin/koru-arrayed-capture 2>/dev/null

# Reference implementations
echo "  Zig..."
zig build-exe reference/nbody.zig -O ReleaseFast -fno-emit-bin -femit-bin=bin/zig-nbody 2>/dev/null

echo "  Rust..."
rustc -C opt-level=3 -C target-cpu=native -o bin/rust-nbody reference/nbody.rs 2>/dev/null

echo "  C..."
clang -O3 -ffast-math -march=native -o bin/c-nbody reference/nbody.c -lm 2>/dev/null

echo ""

# --- Verify correctness ---
echo "Verifying outputs (1000 iterations)..."

KORU_KP=$(bin/koru-kernel-pairwise 1000 2>&1)
KORU_AC=$(bin/koru-arrayed-capture 1000 2>&1)
ZIG=$(bin/zig-nbody 1000 2>&1)
RUST=$(bin/rust-nbody 1000 2>&1)
C=$(bin/c-nbody 1000 2>&1)

MISMATCH=""
[ "$KORU_KP" != "$ZIG" ] && MISMATCH="$MISMATCH koru-kernel-pairwise"
[ "$KORU_AC" != "$ZIG" ] && MISMATCH="$MISMATCH koru-arrayed-capture"
[ "$RUST" != "$ZIG" ] && MISMATCH="$MISMATCH rust"
[ "$C" != "$ZIG" ] && MISMATCH="$MISMATCH c"

if [ -n "$MISMATCH" ]; then
    echo "ERROR: Output mismatch for:$MISMATCH"
    echo ""
    echo "Zig:               $ZIG"
    echo "Koru kernel:       $KORU_KP"
    echo "Koru arrayed:      $KORU_AC"
    echo "Rust:              $RUST"
    echo "C:                 $C"
    exit 1
fi

echo "All outputs match: $ZIG"
echo ""

# --- Benchmark ---
echo "Running benchmark..."
echo ""

hyperfine \
    --warmup 3 \
    --runs "$RUNS" \
    --export-markdown "results.md" \
    --export-json "results.json" \
    -n "Koru (kernel:pairwise)" "bin/koru-kernel-pairwise $ITERS" \
    -n "Koru (arrayed capture)" "bin/koru-arrayed-capture $ITERS" \
    -n "Zig" "bin/zig-nbody $ITERS" \
    -n "Rust" "bin/rust-nbody $ITERS" \
    -n "C" "bin/c-nbody $ITERS"

echo ""
echo "Results saved to: results.md, results.json"
