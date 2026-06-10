#!/usr/bin/env bash
# run.sh <workload> <language> <n>  — runs one (workload, language, n), prints CSV line
# Format: workload,language,n,wall_ms,output_hash,output,note
set -e
WL="$1"
IMPL="$2"
N="$3"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/workloads/$WL/$IMPL"
[ -d "$DIR" ] || { echo "$WL,$IMPL,$N,,,,,no-such-implementation"; exit 1; }

cd "$DIR"

# Pick command per language
case "$IMPL" in
    koru)       CMD="./a.out $N" ;;
    csharp)     CMD="dotnet out/bench.dll $N" ;;
    python)     CMD="python3 bench.py $N" ;;
    javascript) CMD="node bench.js $N" ;;
    rust)       CMD="./target/release/bench $N" ;;
    go)         CMD="./bench $N" ;;
    *)          echo "$WL,$IMPL,$N,,,,,unknown-language"; exit 1 ;;
esac

# Time it, capture output
START=$(python3 -c "import time; print(int(time.monotonic_ns()))")
OUTPUT=$(eval "$CMD" 2>&1 || echo "RUN_FAILED")
END=$(python3 -c "import time; print(int(time.monotonic_ns()))")
WALL_MS=$(echo "scale=3; ($END - $START) / 1000000" | bc)

# Trim and clean output (single line)
OUTPUT_CLEAN=$(echo "$OUTPUT" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
OUTPUT_HASH=$(echo -n "$OUTPUT_CLEAN" | shasum -a 256 | cut -c1-12)

echo "$WL,$IMPL,$N,$WALL_MS,$OUTPUT_HASH,\"$OUTPUT_CLEAN\","
