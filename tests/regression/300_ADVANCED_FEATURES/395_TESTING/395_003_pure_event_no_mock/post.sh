#!/bin/bash
# Run the actual Zig tests to verify pure events work without mocks

cd "$(dirname "$0")"

# Run zig test on the generated output
zig test output_emitted.zig 2>&1
exit $?
