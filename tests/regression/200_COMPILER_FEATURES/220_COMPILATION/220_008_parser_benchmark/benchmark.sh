#!/bin/bash
# Benchmark: Koru Parser Runtime Performance
#
# Measures how fast Koru programs can parse Koru source code at runtime.
# Uses the exact same parser as the compiler frontend and backend.

set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Koru Parser Runtime Benchmark"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "This benchmark measures how fast a Koru program can parse"
echo "Koru source code at runtime using \$std/parser."
echo ""

# Compile the benchmark
echo "📦 Compiling Koru parser benchmark..."
cd /Users/larsde/src/koru
./run_regression.sh 220_008_parser_benchmark > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "❌ ERROR: Compilation failed"
    echo "   Run './run_regression.sh 220_008_parser_benchmark' to see errors"
    exit 1
fi

cd tests/regression/200_COMPILER_FEATURES/220_COMPILATION/220_008_parser_benchmark

if [ ! -f "output" ]; then
    echo "❌ ERROR: No output binary produced"
    exit 1
fi

echo "✅ Compiled successfully"
echo ""

# Verify it runs
echo "🔍 Verifying benchmark runs correctly..."
./output
echo "✅ Benchmark runs correctly"
echo ""

# Check for hyperfine
if ! command -v hyperfine &> /dev/null; then
    echo "⚠️  hyperfine not installed"
    echo "   Install with: brew install hyperfine"
    exit 0
fi

# Run benchmark
echo "🏃 Running benchmark with hyperfine..."
echo ""

hyperfine \
    --warmup 10 \
    --min-runs 100 \
    --style full \
    --shell=none \
    --command-name "Koru Parser (runtime)" "./output"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Benchmark complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
