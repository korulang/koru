#!/bin/bash
# Post-validation for Profile metatype RELEASE mode test
# Shows actual nanosecond-level performance

# Check that actual.txt exists
if [ ! -f actual.txt ]; then
    echo "ERROR: actual.txt not found"
    exit 1
fi

# Extract and display timestamps
echo "=== RELEASE MODE PERFORMANCE ==="
TIMESTAMP1=$(grep "Profile: hello\.done -> goodbye @" actual.txt | sed 's/.*@ //')
TIMESTAMP2=$(grep "Profile: goodbye\.done -> terminal @" actual.txt | sed 's/.*@ //')

if [ -z "$TIMESTAMP1" ] || [ -z "$TIMESTAMP2" ]; then
    echo "ERROR: Could not extract timestamps"
    exit 1
fi

# Calculate time difference (in nanoseconds)
DIFF=$((TIMESTAMP2 - TIMESTAMP1))
echo "First transition:  $TIMESTAMP1 ns"
echo "Second transition: $TIMESTAMP2 ns"
echo "Time difference:   $DIFF ns ($((DIFF / 1000)) microseconds)"
echo ""

# Verify basic correctness
if ! grep -q "Hello executed" actual.txt; then
    echo "ERROR: Missing 'Hello executed' message"
    exit 1
fi

if ! grep -q "Goodbye executed" actual.txt; then
    echo "ERROR: Missing 'Goodbye executed' message"
    exit 1
fi

echo "✓ Release mode profiling working correctly"
echo "✓ Events executed with ${DIFF}ns between them"
exit 0
