#!/bin/bash
# Run the actual Zig tests - this test has a deliberately failing assertion
# We expect zig test to FAIL (non-zero exit) because one test fails

cd "$(dirname "$0")"

# Run zig test on the generated output
output=$(zig test output_emitted.zig 2>&1)
exit_code=$?

echo "$output"

# We EXPECT failure here (exit_code != 0)
# If zig test fails as expected, that's a PASS for this regression test
if [ $exit_code -ne 0 ]; then
    echo ""
    echo "=== Test correctly detected failure (expected behavior) ==="
    exit 0
else
    echo ""
    echo "=== ERROR: Test should have failed but passed ==="
    exit 1
fi
