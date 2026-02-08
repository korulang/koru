#!/bin/bash
# Verify Source parameter is captured in AST AND build.zig is generated

# Get AST as JSON (note: koruc must be in PATH)
AST_JSON=$(koruc --ast-json input.kz 2>&1 | grep -v "^DEBUG:")

# Check that the Source parameter value contains the expected content
if echo "$AST_JSON" | grep -q 'linkSystemLibrary.*sqlite3'; then
    echo "✓ Source parameter captured sqlite3 requirement in AST"
else
    echo "✗ Source parameter did NOT capture sqlite3 requirement"
    echo "AST JSON (first 100 lines):"
    echo "$AST_JSON" | head -100
    exit 1
fi

# Check that build.zig was generated
if [ ! -f build.zig ]; then
    echo "✗ build.zig was NOT generated"
    exit 1
fi

# Check that build.zig contains sqlite3 requirement
if grep -q 'linkSystemLibrary.*sqlite3' build.zig; then
    echo "✓ build.zig contains sqlite3 requirement"
else
    echo "✗ build.zig missing sqlite3 requirement"
    echo "Generated build.zig:"
    cat build.zig
    exit 1
fi

# Check that build.zig has struct namespacing pattern
if grep -q 'compiler_build_.*= struct' build.zig; then
    echo "✓ build.zig uses struct namespacing"
else
    echo "✗ build.zig missing struct namespacing"
    echo "Generated build.zig:"
    cat build.zig
    exit 1
fi

# Check that all three requirements appear in build.zig
if grep -q 'linkSystemLibrary.*sqlite3' build.zig && \
   grep -q 'linkSystemLibrary.*zlib' build.zig && \
   grep -q 'addIncludePath.*vendor/include' build.zig; then
    echo "✓ All three build requirements present in build.zig"
else
    echo "✗ Missing one or more build requirements"
    echo "Generated build.zig:"
    cat build.zig
    exit 1
fi

echo "✅ All validations passed!"
exit 0
