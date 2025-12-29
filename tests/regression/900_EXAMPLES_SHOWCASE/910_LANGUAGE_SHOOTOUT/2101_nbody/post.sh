#!/bin/bash
# Post-validation: Check performance is within threshold
#
# Compares Koru performance against Zig baseline
# Success: ratio < threshold
# Failure: ratio > threshold → investigate and fix compiler

set -e

THRESHOLD_FILE="THRESHOLD"

if [ ! -f "$THRESHOLD_FILE" ]; then
    echo "⚠️  No THRESHOLD file found"
    echo "   Creating default threshold: 1.20 (within 20%)"
    echo "1.20" > THRESHOLD
fi

THRESHOLD=$(cat "$THRESHOLD_FILE")

# ============================================================================
# Run benchmark if results don't exist
# ============================================================================

if [ ! -f "results.json" ]; then
    echo "⚠️  No benchmark results found (results.json missing)"
    echo "   Running benchmark..."
    bash benchmark.sh
fi

if [ ! -f "results.json" ]; then
    echo "❌ FAIL: Benchmark did not produce results.json"
    exit 1
fi

# ============================================================================
# Parse results and calculate ratio
# ============================================================================

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "⚠️  jq not installed (needed to parse benchmark results)"
    echo "   Install with: brew install jq (macOS) or apt install jq (Linux)"
    echo "   Skipping performance validation..."
    exit 0
fi

# hyperfine results.json structure:
# {
#   "results": [
#     { "command": "C (gcc -O3)", "mean": 0.123, ... },
#     { "command": "Zig (ReleaseFast)", "mean": 0.125, ... },
#     { "command": "Koru → Zig", "mean": 0.135, ... }
#   ]
# }

# Extract times
C_TIME=$(jq -r '.results[] | select(.command == "C (gcc -O3)") | .mean' results.json)
ZIG_TIME=$(jq -r '.results[] | select(.command == "Zig (ReleaseFast)") | .mean' results.json)
KORU_TIME=$(jq -r '.results[] | select(.command == "Koru → Zig") | .mean' results.json)

# Calculate ratios
KORU_VS_ZIG=$(echo "scale=4; $KORU_TIME / $ZIG_TIME" | bc -l)
ZIG_VS_C=$(echo "scale=4; $ZIG_TIME / $C_TIME" | bc -l)
KORU_VS_C=$(echo "scale=4; $KORU_TIME / $C_TIME" | bc -l)

# ============================================================================
# Display results
# ============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Performance Results: N-Body Simulation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  C (gcc -O3):        ${C_TIME}s  [gold standard]"
echo "  Zig (ReleaseFast):  ${ZIG_TIME}s  [our target]"
echo "  Koru → Zig:         ${KORU_TIME}s  [event-driven]"
echo ""
echo "  Ratios:"
echo "    Koru / Zig:  ${KORU_VS_ZIG}x"
echo "    Zig / C:     ${ZIG_VS_C}x"
echo "    Koru / C:    ${KORU_VS_C}x"
echo ""
echo "  Threshold:     ${THRESHOLD}x"
echo ""

# ============================================================================
# Check threshold
# ============================================================================

# Compare Koru vs Zig (this is what we care about)
if (( $(echo "$KORU_VS_ZIG > $THRESHOLD" | bc -l) )); then
    echo "❌ PERFORMANCE REGRESSION!"
    echo ""
    echo "  Koru is ${KORU_VS_ZIG}x slower than Zig baseline"
    echo "  Threshold is ${THRESHOLD}x"
    echo "  Exceeded by: $(echo "scale=1; ($KORU_VS_ZIG - $THRESHOLD) * 100" | bc -l)%"
    echo ""
    echo "Action Required:"
    echo "  1. Check emitted code: output_emitted.zig"
    echo "  2. Compare to baseline: reference/baseline.zig"
    echo "  3. Look for extra function calls, allocations, bounds checks"
    echo "  4. Identify missing optimizations"
    echo "  5. Fix compiler, do NOT relax threshold"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1

elif (( $(echo "$KORU_VS_ZIG < 0.95" | bc -l) )); then
    echo "🎉 PERFORMANCE IMPROVED!"
    echo ""
    echo "  Koru is FASTER than baseline (${KORU_VS_ZIG}x)"
    echo "  This is unusual - verify correctness carefully"
    echo "  May indicate measurement noise or compiler cleverness"
    echo ""
    echo "✅ Performance within threshold"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

else
    OVERHEAD=$(echo "scale=1; ($KORU_VS_ZIG - 1) * 100" | bc -l)
    MARGIN=$(echo "scale=1; ($THRESHOLD - $KORU_VS_ZIG) * 100" | bc -l)

    echo "✅ Performance within threshold"
    echo ""
    echo "  Overhead: ${OVERHEAD}%"
    echo "  Margin:   ${MARGIN}% below threshold"
    echo ""
    echo "Context:"
    echo "  - Zig is ${ZIG_VS_C}x vs C (baseline overhead)"
    echo "  - Koru adds $(echo "scale=1; ($KORU_VS_ZIG - $ZIG_VS_C) * 100" | bc -l)% on top of that"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

exit 0
