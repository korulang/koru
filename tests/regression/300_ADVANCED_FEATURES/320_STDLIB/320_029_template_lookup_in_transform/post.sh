#!/bin/bash
# Verify that ~if uses REAL template system

OUTPUT_FILE="output_emitted.zig"

# Check 1: No if_impl handler calls (excluding comments)
if grep -v "^[[:space:]]*//" "$OUTPUT_FILE" | grep -q "if_impl_event.handler"; then
    echo "FAIL: Found if_impl_event.handler - should use inline code"
    exit 1
fi

# Check 2: Has literal if statement with condition
if ! grep -qE "if \(value > 10\)" "$OUTPUT_FILE"; then
    echo "FAIL: Expected 'if (value > 10)' not found"
    exit 1
fi

# Check 3: Verify the template structure was used
# The template produces: if (${condition}) { ${| then |} } else { ${| else |} }
# The branch bodies are comptime print transforms — they land as inline
# debug.print calls inside the if/else (print is a transform, not a runtime
# handler, since 2026-06-11).
if ! grep -q 'debug.print("Template says' "$OUTPUT_FILE"; then
    echo "FAIL: Expected inline print output for then/else bodies not found"
    exit 1
fi

echo "PASS: ~if uses template-based code generation"
exit 0
