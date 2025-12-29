#!/bin/bash
# Benchmark: Event Taps vs The World
# Compare Koru event taps against common event emission patterns
#
# Tests:
# - Node.js: EventEmitter (the canonical JS event system)
# - Go: Callback slices (idiomatic Go pattern)
# - Rust: Vec<Box<dyn Fn>> callbacks
# - C: Function pointer arrays (bare minimum overhead)
# - Koru: Event taps (compile-time AST rewrite)
#
# All emit 10M events from producer to observer
# The question: How much faster is zero-cost observation?

set -e

echo "============================================"
echo "  EVENT TAPS VS THE WORLD"
echo "  Koru Taps vs EventEmitter/Callbacks"
echo "============================================"
echo ""
echo "Pattern: Producer emits 10M events, observer accumulates"
echo ""

# Clean up previous builds
rm -f go_baseline rust_baseline c_baseline koru_taps_output results.json
rm -rf zig-out .zig-cache target backend.zig build_backend.zig

echo "Building Node.js baseline (EventEmitter)..."
# Node.js doesn't need compilation, but let's verify it works
node baseline_node.js > /dev/null 2>&1 || { echo "Node.js baseline failed!"; exit 1; }
echo "  Node.js ready (interpreted)"

echo "Building Go baseline (callbacks)..."
go build -o go_baseline baseline_callbacks.go

echo "Building Rust baseline (callbacks)..."
rustc -O -o rust_baseline baseline_callbacks.rs

echo "Building C baseline (function pointers)..."
cc -O3 -o c_baseline baseline_callbacks.c

echo "Building Koru Taps version..."
# Two-pass compilation

# Pass 1: Frontend - Parse .kz -> backend.zig
koruc input_taps.kz -o backend.zig

# Pass 2: Compile and run backend to generate final code
REL_TO_ROOT=$(realpath --relative-to="$(pwd)" /Users/larsde/src/koru)
sed -i.bak "s|const REL_TO_ROOT = \".\";|const REL_TO_ROOT = \"$REL_TO_ROOT\";|g" build_backend.zig
rm -f build_backend.zig.bak

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
./backend koru_taps_output 2>backend.err
if [ $? -ne 0 ]; then
    echo "ERROR: Backend execution failed"
    cat backend.err
    exit 1
fi

# Clean up build artifacts
rm -rf zig-out .zig-cache backend compile_backend.err backend.err backend.zig build_backend.zig

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
# - warmup: 3 runs to stabilize
# - runs: 10 for statistical significance
# Note: Node.js needs shell to invoke 'node', others use --shell=none
hyperfine --warmup 3 --runs 10 \
    --export-json results.json \
    --command-name "Node.js (EventEmitter)" 'node baseline_node.js' \
    --command-name "Go (callbacks)" './go_baseline' \
    --command-name "Rust (callbacks)" './rust_baseline' \
    --command-name "C (function ptrs)" './c_baseline' \
    --command-name "Koru (taps)" './koru_taps_output'

echo ""
echo "============================================"
echo "Results saved to results.json"
echo ""
echo "The question answered:"
echo "  How much faster is compile-time observation"
echo "  vs runtime event emission?"
echo "============================================"
