#!/bin/bash
# Verify that ~[pure] annotation is preserved in the AST
# The backend can reason about purity during compilation

# Generate AST JSON from the input
# Note: koruc --ast-json generates JSON even with parse errors (for IDE tooling)
AST_JSON=$(koruc --ast-json input.kz 2>&1)

# Check that the add proc has is_pure: true
if ! echo "$AST_JSON" | grep -q '"event_name": "add"'; then
    echo "Missing 'add' proc in AST"
    exit 1
fi

if ! echo "$AST_JSON" | grep -A 10 '"event_name": "add"' | grep -q '"is_pure": true'; then
    echo "'add' proc should have is_pure: true"
    exit 1
fi

# Check that the print_number proc has is_pure: false
if ! echo "$AST_JSON" | grep -q '"event_name": "print_number"'; then
    echo "Missing 'print_number' proc in AST"
    exit 1
fi

if ! echo "$AST_JSON" | grep -A 10 '"event_name": "print_number"' | grep -q '"is_pure": false'; then
    echo "'print_number' proc should have is_pure: false"
    exit 1
fi

echo "✓ Pure annotations correctly preserved in AST"
exit 0
