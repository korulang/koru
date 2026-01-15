#!/bin/bash
# Run the actual Zig tests to verify cross-module mocking works at runtime
cd "$(dirname "$0")"
zig test output_emitted.zig 2>&1
exit $?
