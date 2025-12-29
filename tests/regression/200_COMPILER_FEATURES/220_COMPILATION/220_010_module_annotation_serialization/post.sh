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
# Pattern: .annotations = &.{"comptime"}...compiler.kz (but not compiler_requirements)
if ! grep 'annotations = &\.{"comptime"}.*file.*compiler\.kz' backend.zig | grep -qv compiler_requirements; then
    echo "FAIL: std.compiler should have annotations = &.{\"comptime\"}"
    grep "compiler\.kz" backend.zig | grep -v compiler_requirements | head -1 || echo "(not found)"
    exit 1
fi

# Check std.compiler_requirements has [comptime] annotation only
if ! grep -q 'annotations = &\.{"comptime"}.*compiler_requirements\.kz' backend.zig; then
    echo "FAIL: std.compiler_requirements should have annotations = &.{\"comptime\"}"
    grep "compiler_requirements\.kz" backend.zig | head -1 || echo "(not found)"
    exit 1
fi

echo "PASS: All module annotations correctly serialized"
exit 0
