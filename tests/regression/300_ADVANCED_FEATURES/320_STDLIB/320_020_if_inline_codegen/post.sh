#!/bin/bash
# Verify that the generated code uses literal if/else, NOT event handler call

OUTPUT_FILE="output_emitted.zig"

# Check that if_impl_event.handler is NOT present in actual code (exclude comments)
# Comments start with // so we filter those out first
if grep -v "^[[:space:]]*//" "$OUTPUT_FILE" | grep -q "if_impl_event.handler"; then
    echo "FAIL: Found if_impl_event.handler call - should be literal if/else"
    echo "The ~if transform should emit 'if (condition) { ... } else { ... }'"
    echo "NOT 'if_impl_event.handler(.{ .condition = ... })'"
    exit 1
fi

# Check that literal if statement IS present (good pattern)
# Look for: if (value > 10) or if (main_module.value > 10)
if ! grep -qE "if \([^)]*value > 10" "$OUTPUT_FILE"; then
    echo "FAIL: Expected literal 'if (value > 10)' not found"
    echo "The ~if transform should emit a literal Zig if statement"
    exit 1
fi

echo "PASS: ~if compiles to zero-overhead literal if/else"
exit 0
