#!/bin/bash
# Post-validation: Check performance is within threshold

set -e

if [ ! -f "results.json" ]; then
    echo "⚠️  No benchmark results found (results.json missing)"
    echo "   Running benchmark..."
    bash benchmark.sh
fi

if [ ! -f "results.json" ]; then
    echo "❌ FAIL: Benchmark did not produce results.json"
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "⚠️  jq not installed (needed to parse benchmark results)"
    echo "   Install with: brew install jq (macOS) or apt install jq (Linux)"
    echo "   Skipping performance validation..."
    exit 0
fi

THRESHOLD=$(cat THRESHOLD)

# Parse results (hyperfine format)
BASELINE_TIME=$(jq -r '.results[0].mean' results.json)
KORU_TIME=$(jq -r '.results[1].mean' results.json)

# Calculate ratio (Koru / Baseline)
RATIO=$(echo "scale=4; $KORU_TIME / $BASELINE_TIME" | bc -l)

echo ""
echo "Performance Results:"
echo "  Baseline (Zig): ${BASELINE_TIME}s"
echo "  Koru:           ${KORU_TIME}s"
echo "  Ratio:          ${RATIO}x"
echo "  Threshold:      ${THRESHOLD}x"
echo ""

# Compare to threshold
if (( $(echo "$RATIO > $THRESHOLD" | bc -l) )); then
    echo "❌ PERFORMANCE REGRESSION!"
    echo "   Koru is ${RATIO}x slower than baseline"
    echo "   Threshold is ${THRESHOLD}x"
    echo "   Regression: $(echo "scale=1; ($RATIO - 1) * 100" | bc -l)%"
    exit 1
elif (( $(echo "$RATIO < 0.95" | bc -l) )); then
    echo "✅ PERFORMANCE IMPROVED!"
    echo "   Koru is FASTER than baseline (${RATIO}x)"
else
    echo "✅ Performance within threshold"
    echo "   Overhead: $(echo "scale=1; ($RATIO - 1) * 100" | bc -l)%"
fi

exit 0
