#!/bin/bash
# Verify module annotations are correctly serialized in backend.zig
# post.sh runs in the test directory, so use relative paths

# AST literal moved from backend.zig to program_ast.zig (split landed 2026-05-20).
# Concatenate both so grep finds serialized AST contents regardless of layout.
cat backend.zig program_ast.zig 2>/dev/null > _combined_emit.zig

# Check std.io has [comptime|runtime] annotations
# Pattern: .annotations = &.{"comptime", "runtime"}...io.kz
if ! grep -q 'annotations = &\.{"comptime", "runtime"}.*io\.kz' _combined_emit.zig; then
    echo "FAIL: std.io should have annotations = &.{\"comptime\", \"runtime\"}"
    grep "io\.kz" _combined_emit.zig | head -1 || echo "(not found)"
    exit 1
fi

# Check std.compiler has [comptime] annotation only
# Pattern: .annotations = &.{"comptime"}...compiler.kz
if ! grep -q 'annotations = &\.{"comptime"}.*compiler\.kz' _combined_emit.zig; then
    echo "FAIL: std.compiler should have annotations = &.{\"comptime\"}"
    grep "compiler\.kz" _combined_emit.zig | head -1 || echo "(not found)"
    exit 1
fi

# NOTE: compiler_requirements.kz was removed - its functionality merged into compiler.kz

echo "PASS: All module annotations correctly serialized"
exit 0
