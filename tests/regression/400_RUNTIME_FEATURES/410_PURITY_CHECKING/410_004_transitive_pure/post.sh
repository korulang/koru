#!/bin/bash
# Verify transitive purity through flow composition
#
# Test expectations:
# - multiply: marked ~[pure] → is_pure=true, is_transitively_pure=true
# - add: marked ~[pure] → is_pure=true, is_transitively_pure=true

if [ ! -f "backend.zig" ]; then
    echo "✗ backend.zig not found"
    exit 1
fi

# Search for user-defined procs (from "input" module) and check purity
# The multiply proc should have both is_pure = true and is_transitively_pure = true

# Check multiply proc - look for the proc_decl section with module "input" and name "multiply"
# This is more robust than line numbers
MULTIPLY_FOUND=0
if grep -B 2 -A 20 'module_qualifier = "input".*"multiply"' backend.zig | grep -q 'proc_decl = ProcDecl'; then
    MULTIPLY_SECTION=$(grep -B 2 -A 20 'module_qualifier = "input".*"multiply"' backend.zig | grep -A 18 'proc_decl = ProcDecl')
    if echo "$MULTIPLY_SECTION" | grep -q '.is_pure = true'; then
        echo "✓ multiply: is_pure = true"
        if echo "$MULTIPLY_SECTION" | grep -q '.is_transitively_pure = true'; then
            echo "✓ multiply: is_transitively_pure = true"
            MULTIPLY_FOUND=1
        else
            echo "✗ FAIL: multiply should be is_transitively_pure = true"
            exit 1
        fi
    else
        echo "✗ FAIL: multiply should be is_pure = true (marked ~[pure])"
        exit 1
    fi
fi

if [ $MULTIPLY_FOUND -eq 0 ]; then
    echo "✗ FAIL: Could not find multiply proc_decl"
    exit 1
fi

# Check add proc
ADD_FOUND=0
if grep -B 2 -A 20 'module_qualifier = "input".*"add"' backend.zig | grep -q 'proc_decl = ProcDecl'; then
    ADD_SECTION=$(grep -B 2 -A 20 'module_qualifier = "input".*"add"' backend.zig | grep -A 18 'proc_decl = ProcDecl')
    if echo "$ADD_SECTION" | grep -q '.is_pure = true'; then
        echo "✓ add: is_pure = true"
        if echo "$ADD_SECTION" | grep -q '.is_transitively_pure = true'; then
            echo "✓ add: is_transitively_pure = true"
            ADD_FOUND=1
        else
            echo "✗ FAIL: add should be is_transitively_pure = true"
            exit 1
        fi
    else
        echo "✗ FAIL: add should be is_pure = true (marked ~[pure])"
        exit 1
    fi
fi

if [ $ADD_FOUND -eq 0 ]; then
    echo "✗ FAIL: Could not find add proc_decl"
    exit 1
fi

echo ""
echo "✓ Transitive purity verified through flow composition"
echo "  Optimizer can see: add (pure) -> multiply (pure) -> print (impure)"

exit 0
