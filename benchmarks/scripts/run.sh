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
    c)          CMD="./bench $N" ;;
    go)         CMD="./bench $N" ;;
    *)          echo "$WL,$IMPL,$N,,,,,unknown-language"; exit 1 ;;
esac

# Time it, capture output. `|| echo RUN_FAILED` used to swallow the exit code:
# a missing binary or a crash still produced a NORMAL row — a real-looking
# wall_ms (the cost of failing), a hash of the error text, exit 0, and an EMPTY
# `note`, the column that exists to catch precisely this. Appended to a results
# CSV that reads as a measurement, and a table built from it reports a time for a
# benchmark that never ran. The two STATIC failures above already set a note; the
# failure of the run itself was the one that did not.
START=$(python3 -c "import time; print(int(time.monotonic_ns()))")
set +e
OUTPUT=$(eval "$CMD" 2>&1)
RC=$?
set -e
END=$(python3 -c "import time; print(int(time.monotonic_ns()))")
WALL_MS=$(echo "scale=3; ($END - $START) / 1000000" | bc)

# Trim and clean output (single line)
OUTPUT_CLEAN=$(echo "$OUTPUT" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
OUTPUT_HASH=$(echo -n "$OUTPUT_CLEAN" | shasum -a 256 | cut -c1-12)

# A run that failed is not a measurement. No wall_ms, no hash — a blank cell
# cannot be plotted, where a number can.
if [ "$RC" -ne 0 ]; then
    echo "$WL,$IMPL,$N,,,\"$OUTPUT_CLEAN\",run-failed"
    exit 1
fi

echo "$WL,$IMPL,$N,$WALL_MS,$OUTPUT_HASH,\"$OUTPUT_CLEAN\","
