#!/bin/bash
# Post-validation: Verify timing instrumentation worked
#
# Checks that:
# 1. Timer output appears in backend.err
# 2. Timing value is reasonable (> 0ms, < 60000ms)

set -e

if [ ! -f "backend.err" ]; then
    echo "❌ FAIL: No backend.err file found"
    exit 1
fi

# Extract the timing line
TIMING_LINE=$(grep "⏱️  Compilation took" backend.err || true)

if [ -z "$TIMING_LINE" ]; then
    echo "❌ FAIL: No timing output found in backend.err"
    echo "   Expected: ⏱️  Compilation took X.XXms"
    exit 1
fi

# Extract the milliseconds value
MS=$(echo "$TIMING_LINE" | sed -n 's/.*took \([0-9.]*\)ms.*/\1/p')

if [ -z "$MS" ]; then
    echo "❌ FAIL: Could not parse timing value from: $TIMING_LINE"
    exit 1
fi

# Validate timing is reasonable (using awk for float comparison)
VALID=$(awk -v ms="$MS" 'BEGIN { print (ms > 0 && ms < 60000) ? "yes" : "no" }')

if [ "$VALID" != "yes" ]; then
    echo "❌ FAIL: Timing value out of range: ${MS}ms"
    echo "   Expected: 0 < ms < 60000"
    exit 1
fi

echo "✅ Timing instrumentation working: ${MS}ms"
exit 0
