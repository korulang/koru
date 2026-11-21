#!/bin/bash
# Pin: every `.file = "…"` literal in backend_output_emitted.zig escapes
# backslashes. Strip all `\\` pairs, then any remaining `\` is a raw
# Windows path separator that zig's lexer would refuse.
set -u
src=backend_output_emitted.zig
if [ ! -f "$src" ]; then
    echo "FAIL: no $src"
    exit 1
fi
bad=$(grep -o '\.file = "[^"]*"' "$src" | sed 's/\\\\//g' | grep -c '\\' || true)
if [ "$bad" != "0" ]; then
    echo "FAIL: $bad .file literal(s) carry unescaped backslashes"
    grep -o '\.file = "[^"]*"' "$src" | sed 's/\\\\//g' | grep '\\' | head -3
    exit 1
fi
echo "PASS: all .file literals escape backslashes"
exit 0
