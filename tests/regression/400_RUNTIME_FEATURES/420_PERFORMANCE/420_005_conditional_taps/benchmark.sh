#!/bin/bash
# Benchmark: Conditional Taps vs Conditional Callbacks
# When handlers have conditions, callbacks dispatch ALL then check.
# Taps with `when` clauses compile to direct branch checks.
#
# Scenario: 10M events, 10 handlers/taps
# Each handler only cares about 1/10th of values
# Callbacks: 100M dispatches, 90M do nothing
# Taps: 100M branch checks (cheap), 10M actual calls

set -e

echo "============================================"
echo "  CONDITIONAL TAPS BENCHMARK"
echo "  when clauses vs internal condition checks"
echo "============================================"
echo ""
echo "Scenario: 10M events, 10 handlers each with range condition"
echo "Callbacks: Dispatch ALL, each checks condition"
echo "Taps: when clauses compile to direct branches"
echo ""

# Clean up
rm -f c_conditional koru_conditional results.json
rm -rf zig-out .zig-cache backend.zig build_backend.zig

echo "Building C baseline (conditional handlers)..."
cc -O3 -o c_conditional baseline_c.c

echo "Building Koru (conditional taps with when)..."
koruc input_taps.kz -o backend.zig

REL_TO_ROOT=$(realpath --relative-to="$(pwd)" /Users/larsde/src/koru)
sed -i.bak "s|const REL_TO_ROOT = \".\";|const REL_TO_ROOT = \"$REL_TO_ROOT\";|g" build_backend.zig
rm -f build_backend.zig.bak

zig build --build-file build_backend.zig 2>/dev/null
mv zig-out/bin/backend ./backend
./backend koru_conditional 2>/dev/null

rm -rf zig-out .zig-cache backend backend.zig build_backend.zig backend_output_emitted.zig build.zig output_emitted.zig

echo ""
echo "Running benchmarks..."
echo ""

if ! command -v hyperfine &> /dev/null; then
    echo "ERROR: hyperfine not installed"
    exit 1
fi

hyperfine --warmup 3 --runs 10 \
    --export-json results.json \
    --command-name "C (conditional callbacks)" './c_conditional' \
    --command-name "Koru (when taps)" './koru_conditional'

echo ""
echo "============================================"
echo "Results saved to results.json"
echo ""
echo "The insight:"
echo "  Callbacks: dispatch ALL, then check condition"
echo "  Taps: condition IS the dispatch (just a branch)"
echo "============================================"
