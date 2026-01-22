#!/bin/bash
# Post-validation: Verify BOTH timing outputs appear
# This proves that the two overrides composed correctly

set -e

if [ ! -f "backend.err" ]; then
    echo "❌ FAIL: No backend.err file found"
    exit 1
fi

# Check for frontend timing
if ! grep -q "⏱️.*frontend:" backend.err; then
    echo "❌ Missing frontend timing output"
    exit 1
fi
echo "✅ Frontend timing found"

# Check for total pipeline timing
if ! grep -q "⏱️.*TOTAL PIPELINE:" backend.err; then
    echo "❌ Missing total pipeline timing output"
    exit 1
fi
echo "✅ Total pipeline timing found"

# Display both timings
echo ""
echo "Timing results:"
grep "⏱️" backend.err

echo ""
echo "🎉 Composed timing working! Both overrides fire independently."
exit 0
