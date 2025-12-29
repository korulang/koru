#!/bin/bash
# Verify that the generated code uses literal for loop, NOT synthetic event

OUTPUT_FILE="output_emitted.zig"

# Check that __for synthetic event is NOT present (bad pattern)
# grep -v "^[[:space:]]*//" excludes comment lines
if grep -v "^[[:space:]]*//" "$OUTPUT_FILE" | grep -q "__for.*_event.handler\|for_synthetic.*_event.handler"; then
    echo "FAIL: Found synthetic __for event handler call"
    echo "The ~for transform should emit 'for (range) |item| { ... }'"
    echo "NOT a synthetic event with captured loop body"
    exit 1
fi

# Check that literal for loop IS present (good pattern)
if ! grep -qE "for \(0\.\.5\) \|" "$OUTPUT_FILE"; then
    echo "FAIL: Expected literal 'for (0..5) |...|' not found"
    echo "The ~for transform should emit a literal Zig for loop"
    exit 1
fi

echo "PASS: ~for compiles to zero-overhead literal for loop"
exit 0
