#!/bin/bash
# ============================================================================
# MPMC Algorithm Benchmark
# ============================================================================
# Compares Vyukov's bounded MPMC vs Protheus-style sub-queue partitioning
#
# Scenarios tested:
# - SPSC (1 producer, 1 consumer) - baseline
# - MPMC 4x4 (4 producers, 4 consumers)
# - MPMC 8x8 (8 producers, 8 consumers)
#
# All scenarios push 10M messages through the queue.
# ============================================================================

set -e

cd "$(dirname "$0")"

echo "============================================"
echo "  MPMC ALGORITHM BENCHMARK"
echo "  Vyukov vs Protheus (Sub-Queue)"
echo "============================================"
echo ""

# Clean previous builds
rm -f bench_mpmc results.json
rm -rf .zig-cache zig-out

echo "Building benchmark..."
zig build-exe bench_mpmc.zig -O ReleaseFast -femit-bin=bench_mpmc 2>&1

# Verify it works
echo ""
echo "Verifying correctness..."
./bench_mpmc vyukov_spsc
./bench_mpmc protheus_spsc
./bench_mpmc vyukov_mpmc_4
./bench_mpmc protheus_mpmc_4

echo ""
echo "============================================"
echo "Running benchmarks with hyperfine..."
echo "============================================"
echo ""

# Check if hyperfine is installed
if ! command -v hyperfine &> /dev/null; then
    echo "ERROR: hyperfine not installed"
    echo "Install with: brew install hyperfine (macOS) or cargo install hyperfine"
    exit 1
fi

# Run SPSC comparison
echo "=== SPSC (1 Producer, 1 Consumer) ==="
hyperfine --warmup 2 --runs 5 --shell=none \
    --command-name "Vyukov SPSC" './bench_mpmc vyukov_spsc' \
    --command-name "Protheus SPSC" './bench_mpmc protheus_spsc'

echo ""
echo "=== MPMC 4x4 (4 Producers, 4 Consumers) ==="
hyperfine --warmup 2 --runs 5 --shell=none \
    --command-name "Vyukov 4P/4C" './bench_mpmc vyukov_mpmc_4' \
    --command-name "Protheus 4P/4C" './bench_mpmc protheus_mpmc_4'

echo ""
echo "=== MPMC 8x8 (8 Producers, 8 Consumers) ==="
hyperfine --warmup 2 --runs 5 --shell=none \
    --command-name "Vyukov 8P/8C" './bench_mpmc vyukov_mpmc_8' \
    --command-name "Protheus 8P/8C" './bench_mpmc protheus_mpmc_8'

echo ""
echo "============================================"
echo "Full comparison (all scenarios)..."
echo "============================================"
hyperfine --warmup 2 --runs 5 --shell=none \
    --export-json results.json \
    --command-name "Vyukov SPSC" './bench_mpmc vyukov_spsc' \
    --command-name "Protheus SPSC" './bench_mpmc protheus_spsc' \
    --command-name "Vyukov 4P/4C" './bench_mpmc vyukov_mpmc_4' \
    --command-name "Protheus 4P/4C" './bench_mpmc protheus_mpmc_4' \
    --command-name "Vyukov 8P/8C" './bench_mpmc vyukov_mpmc_8' \
    --command-name "Protheus 8P/8C" './bench_mpmc protheus_mpmc_8'

echo ""
echo "============================================"
echo "Benchmark complete! Results saved to results.json"
echo "============================================"
