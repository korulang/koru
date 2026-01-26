#!/bin/bash
# Verify build steps executed in correct dependency order

if [[ ! -f "steps.log" ]]; then
    echo "FAIL: steps.log not found"
    exit 1
fi

EXPECTED="step:compile_backend
step:build
step:run"

ACTUAL=$(cat "steps.log")

if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    echo "FAIL: Steps executed in wrong order"
    echo "Expected:"
    echo "$EXPECTED"
    echo "Actual:"
    echo "$ACTUAL"
    rm -f "steps.log"
    exit 1
fi

echo "PASS: Build steps executed in correct dependency order"
rm -f "steps.log"
exit 0
