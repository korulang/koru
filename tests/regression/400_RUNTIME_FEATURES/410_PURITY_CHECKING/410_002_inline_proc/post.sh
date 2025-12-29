#!/bin/bash
# Verify pure proc + flow composition pattern
#
# Test expectations:
# - multiply proc: marked ~[pure] → is_pure=true, is_transitively_pure=true ✓
# - print_result proc: unmarked → is_pure=false (has I/O)
# - Flow composition makes full pipeline visible to optimizer

if [ ! -f "backend.zig" ]; then
    echo "✗ backend.zig not found"
    exit 1
fi

# Test 1: multiply proc should be is_pure=true and is_transitively_pure=true
# Extract proc_decl around line 1822 (the multiply proc, not event)
MULTIPLY_START=$(grep -n 'proc_decl.*ProcDecl' backend.zig | grep -A 1 "1822" | head -1 | cut -d: -f1)
if [ -z "$MULTIPLY_START" ]; then
    MULTIPLY_START=1821
fi
MULTIPLY_PROC=$(sed -n "${MULTIPLY_START},$((MULTIPLY_START+20))p" backend.zig)

if ! echo "$MULTIPLY_PROC" | grep -q 'segments = &\[_\]\[\]const u8{"multiply"}'; then
    echo "✗ FAIL: Could not find multiply proc"
    exit 1
fi

if ! echo "$MULTIPLY_PROC" | grep -q '.is_pure = true'; then
    echo "✗ FAIL: multiply proc should have is_pure = true"
    exit 1
fi
echo "✓ multiply proc: is_pure = true (marked ~[pure])"

if ! echo "$MULTIPLY_PROC" | grep -q '.is_transitively_pure = true'; then
    echo "✗ FAIL: multiply proc should have is_transitively_pure = true"
    exit 1
fi
echo "✓ multiply proc: is_transitively_pure = true (no impure calls)"

# Test 2: print_result proc should be is_pure=false (has I/O)
# Line 1862 is the print_result proc
PRINT_PROC=$(sed -n '1860,1880p' backend.zig)

if ! echo "$PRINT_PROC" | grep -q '.is_pure = false'; then
    echo "✗ FAIL: print_result proc should have is_pure = false"
    exit 1
fi
echo "✓ print_result proc: is_pure = false (has I/O)"

echo ""
echo "✓ Flow composition pattern: procs are pure, composition through flows"
echo "  This makes the entire pipeline visible to the optimizer!"

exit 0
