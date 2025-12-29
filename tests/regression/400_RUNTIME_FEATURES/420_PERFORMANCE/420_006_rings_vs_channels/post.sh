#!/bin/bash
# Post-validation: Report performance comparison
#
# Comparing Go vs Zig vs Rust vs Koru vs Koru Taps
# Goal: Prove Koru matches Zig/Rust (zero-cost abstraction!)

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

# Parse results
GO_TIME=$(jq -r '.results[0].mean' results.json)
ZIG_TIME=$(jq -r '.results[1].mean' results.json)
BCHAN_TIME=$(jq -r '.results[2].mean' results.json)
RUST_TIME=$(jq -r '.results[3].mean' results.json)
KORU_TIME=$(jq -r '.results[4].mean' results.json)
TAPS_TIME=$(jq -r '.results[5].mean' results.json)

# Calculate ratios
ZIG_VS_GO=$(echo "scale=4; $ZIG_TIME / $GO_TIME" | bc -l)
BCHAN_VS_GO=$(echo "scale=4; $BCHAN_TIME / $GO_TIME" | bc -l)
BCHAN_VS_ZIG=$(echo "scale=4; $BCHAN_TIME / $ZIG_TIME" | bc -l)
RUST_VS_GO=$(echo "scale=4; $RUST_TIME / $GO_TIME" | bc -l)
RUST_VS_ZIG=$(echo "scale=4; $RUST_TIME / $ZIG_TIME" | bc -l)
KORU_VS_ZIG=$(echo "scale=4; $KORU_TIME / $ZIG_TIME" | bc -l)
KORU_VS_RUST=$(echo "scale=4; $KORU_TIME / $RUST_TIME" | bc -l)
KORU_VS_GO=$(echo "scale=4; $KORU_TIME / $GO_TIME" | bc -l)
TAPS_VS_ZIG=$(echo "scale=4; $TAPS_TIME / $ZIG_TIME" | bc -l)
TAPS_VS_KORU=$(echo "scale=4; $TAPS_TIME / $KORU_TIME" | bc -l)
TAPS_VS_GO=$(echo "scale=4; $TAPS_TIME / $GO_TIME" | bc -l)

echo ""
echo "=========================================="
echo "  PERFORMANCE COMPARISON"
echo "=========================================="
echo ""
echo "Go (channels):        ${GO_TIME}s"
echo "Zig (MPMC ring):      ${ZIG_TIME}s"
echo "bchan (MPSC):         ${BCHAN_TIME}s"
echo "Rust (crossbeam):     ${RUST_TIME}s"
echo "Koru (events):        ${KORU_TIME}s"
echo "Koru (taps):          ${TAPS_TIME}s"
echo ""
echo "Ratios:"
echo "  Zig/Go:       ${ZIG_VS_GO}x"
echo "  bchan/Go:     ${BCHAN_VS_GO}x"
echo "  bchan/Zig:    ${BCHAN_VS_ZIG}x"
echo "  Rust/Go:      ${RUST_VS_GO}x"
echo "  Rust/Zig:     ${RUST_VS_ZIG}x"
echo "  Koru/Zig:     ${KORU_VS_ZIG}x"
echo "  Koru/Rust:    ${KORU_VS_RUST}x"
echo "  Koru/Go:      ${KORU_VS_GO}x"
echo "  Taps/Zig:     ${TAPS_VS_ZIG}x"
echo "  Taps/Koru:    ${TAPS_VS_KORU}x"
echo "  Taps/Go:      ${TAPS_VS_GO}x"
echo ""

# Interpret: Zig vs Go
echo "Zig vs Go:"
if (( $(echo "$ZIG_VS_GO < 0.95" | bc -l) )); then
    IMPROVEMENT=$(echo "scale=1; (1 - $ZIG_VS_GO) * 100" | bc -l)
    echo "  ✅ Zig is ${IMPROVEMENT}% FASTER than Go"
elif (( $(echo "$ZIG_VS_GO > 1.05" | bc -l) )); then
    SLOWDOWN=$(echo "scale=1; ($ZIG_VS_GO - 1) * 100" | bc -l)
    echo "  ⚠️  Go is ${SLOWDOWN}% faster than Zig"
else
    echo "  ✅ Roughly equal (within 5%)"
fi

echo ""

# Interpret: Rust vs Go
echo "Rust vs Go:"
if (( $(echo "$RUST_VS_GO < 0.95" | bc -l) )); then
    IMPROVEMENT=$(echo "scale=1; (1 - $RUST_VS_GO) * 100" | bc -l)
    echo "  ✅ Rust is ${IMPROVEMENT}% FASTER than Go"
elif (( $(echo "$RUST_VS_GO > 1.05" | bc -l) )); then
    SLOWDOWN=$(echo "scale=1; ($RUST_VS_GO - 1) * 100" | bc -l)
    echo "  ⚠️  Go is ${SLOWDOWN}% faster than Rust"
else
    echo "  ✅ Roughly equal (within 5%)"
fi

echo ""

# Interpret: Rust vs Zig
echo "Rust vs Zig:"
if (( $(echo "$RUST_VS_ZIG < 0.95" | bc -l) )); then
    IMPROVEMENT=$(echo "scale=1; (1 - $RUST_VS_ZIG) * 100" | bc -l)
    echo "  ✅ Rust is ${IMPROVEMENT}% FASTER than Zig"
elif (( $(echo "$RUST_VS_ZIG > 1.05" | bc -l) )); then
    SLOWDOWN=$(echo "scale=1; ($RUST_VS_ZIG - 1) * 100" | bc -l)
    echo "  ⚠️  Zig is ${SLOWDOWN}% faster than Rust"
else
    echo "  ✅ Roughly equal (within 5%)"
fi

echo ""

# Interpret: bchan vs Zig (MPSC vs MPMC comparison)
echo "bchan (MPSC) vs Zig (MPMC):"
if (( $(echo "$BCHAN_VS_ZIG < 0.95" | bc -l) )); then
    IMPROVEMENT=$(echo "scale=1; (1 - $BCHAN_VS_ZIG) * 100" | bc -l)
    echo "  🚀 bchan is ${IMPROVEMENT}% FASTER than Zig!"
    echo "  MPSC pattern shows measurable advantage over MPMC"
elif (( $(echo "$BCHAN_VS_ZIG > 1.05" | bc -l) )); then
    SLOWDOWN=$(echo "scale=1; ($BCHAN_VS_ZIG - 1) * 100" | bc -l)
    echo "  ⚠️  Zig MPMC is ${SLOWDOWN}% faster than bchan MPSC"
else
    echo "  ✅ Roughly equal (within 5%)"
fi

echo ""

# Interpret: Koru vs Zig (CRITICAL!)
echo "Koru vs Zig:"
if (( $(echo "$KORU_VS_ZIG < 1.10" | bc -l) )); then
    if (( $(echo "$KORU_VS_ZIG < 1.01" | bc -l) )); then
        echo "  🎉 ZERO-COST ABSTRACTION PROVEN!"
        echo "  Koru matches Zig baseline (<1% overhead)"
    else
        OVERHEAD=$(echo "scale=1; ($KORU_VS_ZIG - 1) * 100" | bc -l)
        echo "  ✅ Within threshold (${OVERHEAD}% overhead)"
        echo "  Koru's abstractions are nearly zero-cost!"
    fi
else
    OVERHEAD=$(echo "scale=1; ($KORU_VS_ZIG - 1) * 100" | bc -l)
    echo "  ❌ PERFORMANCE REGRESSION!"
    echo "  Koru is ${OVERHEAD}% slower than Zig"
    echo "  This means abstractions have cost - investigate!"
fi

echo ""

# Interpret: Koru vs Go
echo "Koru vs Go:"
if (( $(echo "$KORU_VS_GO < 0.95" | bc -l) )); then
    IMPROVEMENT=$(echo "scale=1; (1 - $KORU_VS_GO) * 100" | bc -l)
    echo "  🚀 KORU IS ${IMPROVEMENT}% FASTER THAN GO!"
    echo "  High-level Koru code beats Go's runtime!"
elif (( $(echo "$KORU_VS_GO > 1.05" | bc -l) )); then
    SLOWDOWN=$(echo "scale=1; ($KORU_VS_GO - 1) * 100" | bc -l)
    echo "  ⚠️  Go is ${SLOWDOWN}% faster than Koru"
else
    echo "  ✅ Roughly equal (within 5%)"
fi

echo ""

# Interpret: Koru Taps vs Zig (THE BIG TEST!)
echo "Koru Taps vs Zig (PURE EVENTS - NO RING!):"
if (( $(echo "$TAPS_VS_ZIG < 0.95" | bc -l) )); then
    IMPROVEMENT=$(echo "scale=1; (1 - $TAPS_VS_ZIG) * 100" | bc -l)
    echo "  🚀 TAPS ARE ${IMPROVEMENT}% FASTER THAN ZIG RING!"
    echo "  Event taps OUTPERFORM lock-free data structures!"
elif (( $(echo "$TAPS_VS_ZIG < 1.01" | bc -l) )); then
    echo "  🎉 TAPS ACHIEVE ZERO-COST!"
    echo "  Pure event observation matches Zig MPMC ring!"
elif (( $(echo "$TAPS_VS_ZIG < 1.10" | bc -l) )); then
    OVERHEAD=$(echo "scale=1; ($TAPS_VS_ZIG - 1) * 100" | bc -l)
    echo "  ✅ Within threshold (${OVERHEAD}% overhead)"
    echo "  Taps are competitive with MPMC rings!"
else
    OVERHEAD=$(echo "scale=1; ($TAPS_VS_ZIG - 1) * 100" | bc -l)
    echo "  ⚠️  Taps are ${OVERHEAD}% slower than Zig ring"
    echo "  (But remember: NO SHARED MEMORY DATA STRUCTURE!)"
fi

echo ""

# Interpret: Taps vs Koru Events
echo "Koru Taps vs Koru Events:"
if (( $(echo "$TAPS_VS_KORU < 0.95" | bc -l) )); then
    IMPROVEMENT=$(echo "scale=1; (1 - $TAPS_VS_KORU) * 100" | bc -l)
    echo "  🚀 TAPS ARE ${IMPROVEMENT}% FASTER!"
    echo "  Pure observation beats ring-wrapping events!"
elif (( $(echo "$TAPS_VS_KORU > 1.05" | bc -l) )); then
    SLOWDOWN=$(echo "scale=1; ($TAPS_VS_KORU - 1) * 100" | bc -l)
    echo "  ⚠️  Ring-based events are ${SLOWDOWN}% faster"
else
    echo "  ✅ Roughly equal (within 5%)"
fi

echo ""

echo "=========================================="

exit 0
