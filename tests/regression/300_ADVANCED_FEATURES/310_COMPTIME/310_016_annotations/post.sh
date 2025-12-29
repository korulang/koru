#!/bin/bash
# Post-validation for test 610: Verify profiling annotation works
# This test checks that profiling output is present, not exact timing values

# Check that output contains expected lines
if ! grep -q "Work executed" actual.txt; then
    echo "Missing 'Work executed' in output"
    exit 1
fi

# Check that profiling annotation added timing information
# We don't check exact value (timing varies), just format: "Duration: <number> ns"
if ! grep -E "^Duration: [0-9]+ ns$" actual.txt; then
    echo "Missing or malformed profiling duration output"
    echo "Expected format: 'Duration: <number> ns'"
    echo "Actual output:"
    cat actual.txt
    exit 1
fi

# All checks passed
exit 0
