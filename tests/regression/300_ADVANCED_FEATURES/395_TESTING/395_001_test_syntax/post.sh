#!/bin/bash
# Run the actual Zig tests to verify mocks work correctly

cd "$(dirname "$0")"

# Run zig test on the generated output
zig test output_emitted.zig 2>&1
exit $?
