#!/bin/bash
# Verify that comptime_main dispatches cross-module comptime flows.
#
# In the working case (same-file comptime, see 210_030), comptime_main looks like:
#   pub fn comptime_main(...) {
#       ...
#       main_module.comptime_flow0(current_program, allocator);
#       return current_program;
#   }
#
# The bug: when the [comptime] event is declared in an imported module,
# comptime_main is empty — no comptime_flowN calls are generated.

BACKEND_EMIT="backend_output_emitted.zig"

if [ ! -f "$BACKEND_EMIT" ]; then
    echo "FAIL: No backend_output_emitted.zig generated"
    exit 1
fi

# Check 1: The event handler should be emitted (this part works)
if grep -q "setup_event" "$BACKEND_EMIT"; then
    echo "OK: setup_event handler is emitted (expected)"
else
    echo "FAIL: setup_event handler not found in $BACKEND_EMIT"
    echo "The cross-module event was not emitted at all."
    exit 1
fi

# Check 2: comptime_main should exist
if ! grep -q "pub fn comptime_main" "$BACKEND_EMIT"; then
    echo "FAIL: No comptime_main function found"
    exit 1
fi

# Check 3: comptime_main should call a comptime_flow function
# Extract comptime_main body (up to the closing brace at the same indent level)
# and check for any comptime_flow call
COMPTIME_MAIN=$(sed -n '/pub fn comptime_main/,/^}/p' "$BACKEND_EMIT")

if echo "$COMPTIME_MAIN" | grep -q "comptime_flow"; then
    echo "PASS: comptime_main dispatches cross-module comptime flow"
    exit 0
else
    echo "FAIL: comptime_main does NOT call any comptime_flow function"
    echo ""
    echo "The cross-module [comptime] event handler is emitted, but"
    echo "comptime_main never calls it. The comptime code would never"
    echo "execute during backend compilation."
    echo ""
    echo "comptime_main contents:"
    echo "$COMPTIME_MAIN"
    exit 1
fi
