#!/bin/bash
set -e

echo "=== Compiling input.kz with koruc ==="
/Users/larsde/src/koru/zig-out/bin/koruc input.kz -o backend.zig > compile_frontend.out 2>&1

echo "=== Compiling backend.zig ==="
zig build -Doptimize=Debug > compile_backend.out 2>&1

echo "=== Running backend with KORU_DUMP_AST=1 ==="
env KORU_DUMP_AST=1 ./backend output_emitted.zig 2>backend_with_dumps.err

echo "=== Checking for AST dumps ==="
if grep -q "AST DUMP" backend_with_dumps.err; then
    echo "✅ AST dumps found!"
    grep -c "AST DUMP" backend_with_dumps.err | xargs -I{} echo "Found {} dump points"
else
    echo "❌ No AST dumps found"
fi
