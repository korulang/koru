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

# Koru fused kernel (step + pairwise + self)
echo "  Koru kernel_fused..."
koruc koru/kernel_fused.kz 2>/dev/null
zig build-exe koru/output_emitted.zig -O ReleaseFast -fno-emit-bin -femit-bin=bin/koru-kernel-fused 2>/dev/null

# Reference implementations
echo "  Zig..."
zig build-exe reference/nbody.zig -O ReleaseFast -fno-emit-bin -femit-bin=bin/zig-nbody 2>/dev/null

echo "  Rust..."
rustc -C opt-level=3 -C target-cpu=native -o bin/rust-nbody reference/nbody.rs 2>/dev/null

echo "  C..."
clang -O3 -ffast-math -march=native -o bin/c-nbody reference/nbody.c -lm 2>/dev/null

echo "  C (scalarized)..."
clang -O3 -ffast-math -march=native -o bin/c-nbody-fixed5 reference/nbody_fixed5.c -lm 2>/dev/null

echo "  C (scalarized, no fast-math)..."
clang -O3 -march=native -o bin/c-nbody-fixed5-nofm reference/nbody_fixed5.c -lm 2>/dev/null

echo "  SBCL..."
sbcl --noinform --non-interactive \
    --eval '(compile-file "reference/nbody.lisp")' \
    --eval '(load "reference/nbody.fasl")' \
    --eval '(sb-ext:save-lisp-and-die "bin/sbcl-nbody" :toplevel (function main) :executable t)' 2>/dev/null

echo "  GHC..."
ghc -O2 -o bin/ghc-nbody reference/nbody.hs 2>/dev/null

echo ""

# --- Verify correctness ---
echo "Verifying outputs (1000 iterations)..."

KORU_KF=$(bin/koru-kernel-fused 1000 2>&1)
ZIG=$(bin/zig-nbody 1000 2>&1)
RUST=$(bin/rust-nbody 1000 2>&1)
C=$(bin/c-nbody 1000 2>&1)
C5=$(bin/c-nbody-fixed5 1000 2>&1)
C5NFM=$(bin/c-nbody-fixed5-nofm 1000 2>&1)
SBCL=$(bin/sbcl-nbody 1000 2>&1)
GHC=$(bin/ghc-nbody 1000 2>&1)

MISMATCH=""
[ "$KORU_KF" != "$ZIG" ] && MISMATCH="$MISMATCH koru-kernel-fused"
[ "$RUST" != "$ZIG" ] && MISMATCH="$MISMATCH rust"
[ "$C" != "$ZIG" ] && MISMATCH="$MISMATCH c"
[ "$C5" != "$ZIG" ] && MISMATCH="$MISMATCH c-fixed5"
[ "$C5NFM" != "$ZIG" ] && MISMATCH="$MISMATCH c-fixed5-nofm"
[ "$SBCL" != "$ZIG" ] && MISMATCH="$MISMATCH sbcl"
[ "$GHC" != "$ZIG" ] && MISMATCH="$MISMATCH ghc"

if [ -n "$MISMATCH" ]; then
    echo "ERROR: Output mismatch for:$MISMATCH"
    echo ""
    echo "Zig:               $ZIG"
    echo "Koru fused:        $KORU_KF"
    echo "Rust:              $RUST"
    echo "C:                 $C"
    echo "C (scalarized):    $C5"
    echo "C (scalar,no-fm):  $C5NFM"
    echo "SBCL:              $SBCL"
    echo "GHC:               $GHC"
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
    -n "Koru (kernel fused)" "bin/koru-kernel-fused $ITERS" \
    -n "Zig" "bin/zig-nbody $ITERS" \
    -n "Rust" "bin/rust-nbody $ITERS" \
    -n "C" "bin/c-nbody $ITERS" \
    -n "C (scalarized)" "bin/c-nbody-fixed5 $ITERS" \
    -n "C (scalarized, no fast-math)" "bin/c-nbody-fixed5-nofm $ITERS" \
    -n "SBCL" "bin/sbcl-nbody $ITERS" \
    -n "GHC" "bin/ghc-nbody $ITERS"

echo ""
echo "Results saved to: results.md, results.json"
