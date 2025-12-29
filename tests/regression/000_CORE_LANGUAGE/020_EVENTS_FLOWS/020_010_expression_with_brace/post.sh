#!/bin/bash
# Verify Expression argument with braces was parsed correctly
# The argument should have name="val" and value="{ foo: 1 }"

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if grep -q 'Arg{ .name = "val", .value = "{ foo: 1 }"' "$SCRIPT_DIR/backend.zig"; then
    echo "✓ Expression argument parsed correctly: name='val', value='{ foo: 1 }'"
    exit 0
else
    echo "ERROR: Expression argument not parsed correctly"
    echo "Expected: Arg{ .name = \"val\", .value = \"{ foo: 1 }\" ... }"
    echo "Searching backend.zig for 'val' args:"
    grep -n "Arg.*val" "$SCRIPT_DIR/backend.zig" | head -5
    exit 1
fi
