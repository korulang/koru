#!/bin/bash
# Post-validation: Verify frontend timing output

set -e

if [ ! -f "backend.err" ]; then
    echo "❌ FAIL: No backend.err file found"
    exit 1
fi

# Check for frontend timing
if ! grep -q "⏱️  frontend:" backend.err; then
    echo "❌ FAIL: No frontend timing found"
    exit 1
fi

# Extract and display the timing
TIMING=$(grep "⏱️  frontend:" backend.err)
echo "✅ Frontend timing found: $TIMING"
exit 0
