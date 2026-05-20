#!/bin/bash
# Verify: program with [pure] on an event compiled cleanly.
# Annotations are open metadata at the frontend — misplaced
# annotations are not rejected.

if [ ! -f "backend.zig" ]; then
    echo "✗ backend.zig not found — program failed to compile, but [pure] on event should be legal"
    exit 1
fi

# AST literal moved from backend.zig to program_ast.zig (split landed 2026-05-20).
# Concatenate both so grep finds serialized AST contents regardless of layout.
cat backend.zig program_ast.zig 2>/dev/null > _combined_emit.zig

if grep -q '"noop"' _combined_emit.zig; then
    echo "✓ program with [pure] on event compiled cleanly (annotations are open metadata)"
else
    echo "✗ FAIL: noop event not found in backend.zig"
    exit 1
fi

exit 0
