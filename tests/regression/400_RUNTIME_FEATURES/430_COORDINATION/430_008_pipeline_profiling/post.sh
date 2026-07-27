#!/bin/bash
# Post-validation: Verify elaborate timing output

set -e

if [ ! -f "backend.err" ]; then
    echo "❌ FAIL: No backend.err file found"
    exit 1
fi

# Check for elaborate timing
if ! grep -q "⏱️  elaborate:" backend.err; then
    echo "❌ FAIL: No elaborate timing found"
    exit 1
fi

# Extract and display the timing
TIMING=$(grep "⏱️  elaborate:" backend.err)
echo "✅ Elaborate timing found: $TIMING"
exit 0
