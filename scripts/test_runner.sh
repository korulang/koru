#!/bin/bash

# Test runner for Koru examples
echo "🧪 Running Koru compiler tests..."

# Build the compiler
echo "Building Koru compiler..."
zig build 2>/dev/null || { echo "❌ Build failed"; exit 1; }

# Test examples
EXAMPLES=("branch_constructor_test" "subflow_with_constructors")
PASS=0
FAIL=0

for example in "${EXAMPLES[@]}"; do
    echo -n "Testing $example.kz... "
    if ./zig-out/bin/koruc "examples/$example.kz" 2>/dev/null; then
        # Check if output file was created
        if [ -f "examples/$example.zig" ]; then
            echo "✅ Pass"
            ((PASS++))
        else
            echo "❌ Fail (no output file)"
            ((FAIL++))
        fi
    else
        echo "❌ Fail (compilation error)"
        ((FAIL++))
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ $FAIL -eq 0 ]; then
    echo "🎉 All tests passed!"
    exit 0
else
    echo "⚠️ Some tests failed"
    exit 1
fi