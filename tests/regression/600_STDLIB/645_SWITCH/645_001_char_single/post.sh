#!/bin/bash
# Verify std/switch:char lowers to a native Zig switch, not a regex DFA.

OUTPUT_FILE="output_emitted.zig"

if ! grep -qE "switch \(__koru_switch_value_[0-9]+_[0-9]+\)" "$OUTPUT_FILE"; then
    echo "FAIL: expected 'switch (__koru_switch_value_...)' in emitted Zig"
    exit 1
fi

echo "PASS: std/switch:char emits a Zig switch"
exit 0
