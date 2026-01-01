#!/bin/bash
# Verify module annotations are correctly serialized in backend.zig
# post.sh runs in the test directory, so use relative paths

# Check std.io has [comptime|runtime] annotations
# Pattern: .annotations = &.{"comptime", "runtime"}...io.kz
if ! grep -q 'annotations = &\.{"comptime", "runtime"}.*io\.kz' backend.zig; then
    echo "FAIL: std.io should have annotations = &.{\"comptime\", \"runtime\"}"
    grep "io\.kz" backend.zig | head -1 || echo "(not found)"
    exit 1
fi

# Check std.compiler has [comptime] annotation only
# Pattern: .annotations = &.{"comptime"}...compiler.kz
if ! grep -q 'annotations = &\.{"comptime"}.*compiler\.kz' backend.zig; then
    echo "FAIL: std.compiler should have annotations = &.{\"comptime\"}"
    grep "compiler\.kz" backend.zig | head -1 || echo "(not found)"
    exit 1
fi

# NOTE: compiler_requirements.kz was removed - its functionality merged into compiler.kz

echo "PASS: All module annotations correctly serialized"
exit 0
