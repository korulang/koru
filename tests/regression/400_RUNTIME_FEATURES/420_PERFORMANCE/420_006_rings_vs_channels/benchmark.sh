#!/bin/bash
# Benchmark: Concurrent Message Passing
# Compare Go channels vs Zig MPMC rings vs Rust channels vs Koru events vs Koru taps
#
# Tests:
# - Go: Buffered channels (idiomatic Go)
# - Zig: MPMC ring (Vyukov's lock-free algorithm)
# - Rust: Crossbeam bounded channels (lock-free)
# - Koru: Events/flows wrapping MPMC ring
# - Koru Taps: Pure event-based producer/consumer (no ring!)
#
# All send/receive 10M messages between producer/consumer threads
# Success criteria: Koru should match Zig (zero-cost abstraction!)

set -e

echo "============================================"
echo "  CONCURRENT MESSAGE PASSING BENCHMARK"
echo "  Go vs Zig vs Rust vs Koru vs Koru Taps"
echo "============================================"
echo ""

# Clean up previous builds
rm -f go_baseline zig_baseline rust_baseline bchan_baseline koru_output koru_taps_output backend backend.zig output_emitted.zig results.json
rm -rf zig-out .zig-cache target compile_backend.err backend.err Cargo.lock

echo "Building Go baseline (channels)..."
go build -o go_baseline baseline.go

echo "Building Zig baseline (MPMC ring)..."
zig build-exe baseline.zig -O ReleaseFast -femit-bin=zig_baseline

echo "Building Rust baseline (crossbeam channels)..."
cargo build --release --quiet
cp target/release/rust_baseline ./rust_baseline

echo "Building bchan baseline (MPSC)..."
zig build-exe -O ReleaseFast --dep bchan -Mroot=baseline_bchan.zig -Mbchan=vendor_bchan/src/lib.zig -femit-bin=bchan_baseline

echo "Building Koru version (events + MPMC)..."
# Two-pass compilation (see run_regression.sh for details)

# Pass 1: Frontend - Parse .kz -> backend.zig
koruc input.kz -o backend.zig

# Pass 2: Compile and run backend to generate final code
# koruc already generated build_backend.zig with all required modules
# Fix the REL_TO_ROOT path to point to the repo root
REL_TO_ROOT=$(realpath --relative-to="$(pwd)" /Users/larsde/src/koru)
sed -i.bak "s|const REL_TO_ROOT = \".\";|const REL_TO_ROOT = \"$REL_TO_ROOT\";|g" build_backend.zig
rm build_backend.zig.bak

# Compile backend using the generated build file
zig build --build-file build_backend.zig 2>compile_backend.err
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to compile backend"
    cat compile_backend.err
    exit 1
fi

# Move backend to current directory
mv zig-out/bin/backend ./backend

# Run backend to generate and compile final executable
./backend koru_output 2>backend.err
if [ $? -ne 0 ]; then
    echo "ERROR: Backend execution failed"
    cat backend.err
    exit 1
fi

# Clean up build artifacts
rm -rf zig-out .zig-cache backend compile_backend.err backend.err

echo "Building Koru Taps version (pure events, no ring)..."
# Two-pass compilation for taps variant

# Pass 1: Frontend - Parse .kz -> backend.zig (same name, build_backend.zig references it)
koruc input_taps.kz -o backend.zig

# Pass 2: Compile and run backend to generate final code
# koruc already generated build_backend.zig with all required modules
# Fix the REL_TO_ROOT path to point to the repo root
REL_TO_ROOT=$(realpath --relative-to="$(pwd)" /Users/larsde/src/koru)
sed -i.bak "s|const REL_TO_ROOT = \".\";|const REL_TO_ROOT = \"$REL_TO_ROOT\";|g" build_backend.zig
rm build_backend.zig.bak

# Compile backend using the generated build file
zig build --build-file build_backend.zig 2>compile_backend.err
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to compile taps backend"
    cat compile_backend.err
    exit 1
fi

# Move backend to current directory
mv zig-out/bin/backend ./backend

# Run backend to generate and compile final executable
./backend koru_taps_output 2>backend.err
if [ $? -ne 0 ]; then
    echo "ERROR: Taps backend execution failed"
    cat backend.err
    exit 1
fi

# Clean up build artifacts
rm -rf zig-out .zig-cache backend compile_backend.err backend.err

echo ""
echo "Running benchmarks with hyperfine..."
echo ""

# Check if hyperfine is installed
if ! command -v hyperfine &> /dev/null; then
    echo "ERROR: hyperfine not installed"
    echo "Install with: brew install hyperfine (macOS) or cargo install hyperfine"
    exit 1
fi

# Run benchmark
# - warmup: 3 runs to stabilize (message passing can vary)
# - runs: 10 (fewer than simple loop since this takes longer)
# - shell=none: avoid shell overhead
hyperfine --warmup 3 --runs 10 --shell=none \
    --export-json results.json \
    --command-name "Go (channels)" './go_baseline' \
    --command-name "Zig (MPMC)" './zig_baseline' \
    --command-name "bchan (MPSC)" './bchan_baseline' \
    --command-name "Rust (crossbeam)" './rust_baseline' \
    --command-name "Koru (events)" './koru_output' \
    --command-name "Koru (taps)" './koru_taps_output'

echo ""
echo "============================================"
echo "Benchmark complete! Results saved to results.json"
echo "============================================"
