#!/bin/bash
# Verify transitive impurity propagation
#
# Test expectations:
# - log: NOT marked ~[pure], does I/O → is_pure=false, is_transitively_pure=false
# - multiply: marked ~[pure], calls nothing → is_pure=true, is_transitively_pure=true
# - compute_with_logging: marked ~[pure], calls log (impure) → is_pure=true, is_transitively_pure=FALSE

if [ ! -f "backend.zig" ]; then
    echo "✗ backend.zig not found"
    exit 1
fi

# Check log proc - should be impure (not marked)
LOG_LINE=$(grep -n 'segments = @constCast(&\[_\]\[\]const u8{"log"})' backend.zig | \
           tail -1 | cut -d: -f1)

if [ -z "$LOG_LINE" ]; then
    echo "✗ Could not find log proc"
    exit 1
fi

LOG_PROC=$(sed -n "${LOG_LINE},$((LOG_LINE + 20))p" backend.zig)

if echo "$LOG_PROC" | grep -q '.is_pure = false'; then
    echo "✓ log: is_pure = false (not marked ~[pure])"
else
    echo "✗ FAIL: log should be is_pure = false (unmarked proc)"
    exit 1
fi

if echo "$LOG_PROC" | grep -q '.is_transitively_pure = false'; then
    echo "✓ log: is_transitively_pure = false"
else
    echo "✗ FAIL: log should be is_transitively_pure = false"
    exit 1
fi

# Check multiply proc - should be pure
MULTIPLY_LINE=$(grep -n 'segments = @constCast(&\[_\]\[\]const u8{"multiply"})' backend.zig | \
                tail -1 | cut -d: -f1)

if [ -z "$MULTIPLY_LINE" ]; then
    echo "✗ Could not find multiply proc"
    exit 1
fi

MULTIPLY_PROC=$(sed -n "${MULTIPLY_LINE},$((MULTIPLY_LINE + 20))p" backend.zig)

if echo "$MULTIPLY_PROC" | grep -q '.is_pure = true'; then
    echo "✓ multiply: is_pure = true"
else
    echo "✗ FAIL: multiply should be is_pure = true (marked ~[pure])"
    exit 1
fi

if echo "$MULTIPLY_PROC" | grep -q '.is_transitively_pure = true'; then
    echo "✓ multiply: is_transitively_pure = true (calls nothing)"
else
    echo "✗ FAIL: multiply should be is_transitively_pure = true"
    exit 1
fi

# Check compute_with_logging - locally pure but transitively impure!
COMPUTE_LINE=$(grep -n 'segments = @constCast(&\[_\]\[\]const u8{"compute_with_logging"})' backend.zig | \
               tail -1 | cut -d: -f1)

if [ -z "$COMPUTE_LINE" ]; then
    echo "✗ Could not find compute_with_logging proc"
    exit 1
fi

COMPUTE_PROC=$(sed -n "${COMPUTE_LINE},$((COMPUTE_LINE + 20))p" backend.zig)

if echo "$COMPUTE_PROC" | grep -q '.is_pure = true'; then
    echo "✓ compute_with_logging: is_pure = true (marked ~[pure])"
else
    echo "✗ FAIL: compute_with_logging should be is_pure = true (marked ~[pure])"
    exit 1
fi

if echo "$COMPUTE_PROC" | grep -q '.is_transitively_pure = false'; then
    echo "✓ compute_with_logging: is_transitively_pure = FALSE (calls impure log)"
    echo "  ⚠️  TAINTED by impurity!"
else
    echo "✗ FAIL: compute_with_logging should be is_transitively_pure = false"
    echo "  It calls log which is impure - transitive purity should be FALSE"
    exit 1
fi

echo ""
echo "✓ Transitive impurity correctly propagates through call chains"

exit 0
