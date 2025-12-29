#!/bin/bash
# Benchmark script for loop optimization variants

set -e

echo "═══════════════════════════════════════════════════════════"
echo "  LOOP OPTIMIZATION BENCHMARK - Scientific Comparison"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Build all variants
echo "🔨 Building variants..."
echo ""

VARIANTS=(
    "v0_theoretical_max"
    "v1_baseline"
    "v2_inline_keyword"
    "v3_inline_force"
    "v4_manual_inline"
    "v5_native_for"
    "v6_no_struct_input"
    "v7_no_union_output"
    "v8_inline_plus_no_struct"
    "v9_inline_body_only"
    "v10_combined_all"
)

for variant in "${VARIANTS[@]}"; do
    echo "  Building $variant..."
    zig build-exe "$variant.zig" -O ReleaseFast -femit-bin="$variant" 2>/dev/null
done

echo ""
echo "✅ All variants built"
echo ""

# Check if hyperfine is installed
if ! command -v hyperfine &> /dev/null; then
    echo "❌ hyperfine not found. Install with: brew install hyperfine"
    exit 1
fi

echo "🏃 Running benchmarks..."
echo ""

# Run benchmarks
hyperfine --warmup 3 --runs 10 \
    --export-json results.json \
    --export-markdown results.md \
    "./v0_theoretical_max" \
    "./v1_baseline" \
    "./v2_inline_keyword" \
    "./v3_inline_force" \
    "./v4_manual_inline" \
    "./v5_native_for" \
    "./v6_no_struct_input" \
    "./v7_no_union_output" \
    "./v8_inline_plus_no_struct" \
    "./v9_inline_body_only" \
    "./v10_combined_all"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  RESULTS"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Show the markdown table
if [ -f results.md ]; then
    cat results.md
fi

echo ""
echo "✅ Benchmark complete"
echo "📊 Results saved to:"
echo "   - results.json (machine-readable)"
echo "   - results.md (human-readable)"
echo ""
