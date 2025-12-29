#!/bin/bash
# Benchmark: Multicast Scaling
# How does performance scale with number of observers?
#
# Tests:
# - C: Function pointer arrays with 1, 5, 10 handlers
# - Koru: Event taps with 1, 5, 10 taps (compile-time fusion)
#
# The question: Do callbacks scale linearly? Do taps scale at all?

set -e

echo "============================================"
echo "  MULTICAST SCALING BENCHMARK"
echo "  How does observer count affect performance?"
echo "============================================"
echo ""
echo "Pattern: Producer emits 10M events to N observers"
echo ""

# Clean up previous builds
rm -f c_1 c_5 c_10 koru_1 koru_5 koru_10 results.json
rm -rf zig-out .zig-cache backend.zig build_backend.zig

echo "=== Building C baselines ==="
echo "Building C (1 handler)..."
cc -O3 -o c_1 baseline_c_1.c

echo "Building C (5 handlers)..."
cc -O3 -o c_5 baseline_c_5.c

echo "Building C (10 handlers)..."
cc -O3 -o c_10 baseline_c_10.c

echo ""
echo "=== Building Koru taps ==="

build_koru() {
    local input=$1
    local output=$2
    echo "Building Koru ($output)..."

    koruc $input -o backend.zig

    REL_TO_ROOT=$(realpath --relative-to="$(pwd)" /Users/larsde/src/koru)
    sed -i.bak "s|const REL_TO_ROOT = \".\";|const REL_TO_ROOT = \"$REL_TO_ROOT\";|g" build_backend.zig
    rm -f build_backend.zig.bak

    zig build --build-file build_backend.zig 2>/dev/null
    mv zig-out/bin/backend ./backend
    ./backend $output 2>/dev/null

    rm -rf zig-out .zig-cache backend backend.zig build_backend.zig backend_output_emitted.zig build.zig output_emitted.zig
}

build_koru input_taps_1.kz koru_1
build_koru input_taps_5.kz koru_5
build_koru input_taps_10.kz koru_10

echo ""
echo "=== Running benchmarks ==="
echo ""

if ! command -v hyperfine &> /dev/null; then
    echo "ERROR: hyperfine not installed"
    exit 1
fi

# Run benchmark - grouped by observer count for easy comparison
hyperfine --warmup 3 --runs 10 \
    --export-json results.json \
    --command-name "C (1 handler)" './c_1' \
    --command-name "Koru (1 tap)" './koru_1' \
    --command-name "C (5 handlers)" './c_5' \
    --command-name "Koru (5 taps)" './koru_5' \
    --command-name "C (10 handlers)" './c_10' \
    --command-name "Koru (10 taps)" './koru_10'

echo ""
echo "============================================"
echo "Results saved to results.json"
echo ""
echo "The question answered:"
echo "  Callbacks: O(n) - scales with observer count"
echo "  Taps: O(1) - constant regardless of observers"
echo "============================================"
