#!/bin/bash
# Run the Zig tests - this test should FAIL because the mock returns
# a different branch than the test expects (union field access mismatch)

cd "$(dirname "$0")"

output=$(zig test output_emitted.zig 2>&1)
exit_code=$?

echo "$output"

# We EXPECT failure here (exit_code != 0)
# If zig test fails as expected, that's a PASS for this regression test
if [ $exit_code -ne 0 ]; then
    echo ""
    echo "=== Test correctly failed on unexpected branch (expected behavior) ==="
    exit 0
else
    echo ""
    echo "=== ERROR: Test should have failed but passed (unexpected branch was silently accepted) ==="
    exit 1
fi
