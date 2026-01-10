#!/bin/bash
# Honest comparison: Koru vs Python vs Lua
# All do the same work: 3 function calls with string->int parsing

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Honest 3-Step Benchmark ==="
echo "Each: add(10,20) -> multiply(30,3) -> subtract(90,5) = 85"
echo "All parse strings to ints (same work)"
echo ""

echo "--- Koru ---"
"$DIR/output" 2>&1
echo ""

echo "--- Python ---"
python3 "$DIR/bench.py"
echo ""

echo "--- Lua ---"
lua "$DIR/bench.lua" 2>/dev/null || lua5.4 "$DIR/bench.lua" 2>/dev/null || echo "(Lua not available)"
echo ""

if command -v hyperfine &> /dev/null; then
    echo "=== Hyperfine Statistical Comparison ==="
    hyperfine --warmup 3 \
        "$DIR/output" \
        "python3 $DIR/bench.py" \
        "lua $DIR/bench.lua" 2>/dev/null || \
    hyperfine --warmup 3 \
        "$DIR/output" \
        "python3 $DIR/bench.py"
fi
