#!/usr/bin/env bash
# build.sh <workload>  — builds all language implementations of a workload
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# With no argument, `$ROOT/workloads/` — the directory of workloads — used to
# satisfy the guard below, so every per-language test failed, nothing was built,
# and the script still printed "build complete: " and exited 0. That green is the
# head of the chain: build says done, run finds no binary, and a comparison table
# ends up reporting a language that never executed.
usage() {
    {
        echo "usage: build.sh <workload>"
        echo
        echo "workloads:"
        for d in "$ROOT"/workloads/*/; do echo "  $(basename "$d")"; done
    } >&2
    exit 2
}
[ "$#" -eq 1 ] && [ -n "${1:-}" ] || usage

WL="$1"
DIR="$ROOT/workloads/$WL"
[ -d "$DIR" ] || { echo "workload not found: $WL" >&2; usage; }

# Every arm that actually produced an artifact. Named at the end, so "complete"
# is a claim with a list behind it rather than a word.
BUILT=""

# Koru
if [ -d "$DIR/koru" ]; then
    echo "[koru] building..."
    cd "$DIR/koru"
    rm -rf zig-out .zig-cache backend.zig build.zig build_backend.zig backend_output_emitted.zig output_emitted.zig build_output.zig build.zig.zon a.out
    KORU_STDLIB=/Users/larsde/src/koru/koru_std KORU_PATH=/Users/larsde/src/koru-libs /Users/larsde/src/koru/zig-out/bin/koruc input.kz -o backend.zig --release=fast > /dev/null
    zig build -Doptimize=ReleaseFast > /dev/null
    ./zig-out/bin/backend > /dev/null
    [ -f a.out ] || { echo "[koru] FAILED to build a.out"; exit 1; }
    BUILT="$BUILT koru"
    echo "[koru] ok"
fi

# C — a plain strict-FP scalar loop, so Koru's reduce can be compared against a
# hand-written native reduction under the same (non-reassociating) float rules.
# The reassociation headroom reference (compile the same bench.c with
# -ffast-math) is documented in the workload README, not built here.
if [ -d "$DIR/c" ]; then
    echo "[c] building..."
    cd "$DIR/c"
    rm -f bench
    cc -O3 -march=native bench.c -o bench
    [ -f bench ] || { echo "[c] FAILED"; exit 1; }
    BUILT="$BUILT c"
    echo "[c] ok"
fi

# C#
if [ -d "$DIR/csharp" ]; then
    echo "[csharp] building..."
    cd "$DIR/csharp"
    rm -rf out bin obj
    dotnet publish -c Release --self-contained false -o out > /dev/null 2>&1
    [ -f out/bench.dll ] || { echo "[csharp] FAILED"; exit 1; }
    BUILT="$BUILT csharp"
    echo "[csharp] ok"
fi

# Go
if [ -d "$DIR/go" ]; then
    echo "[go] building..."
    cd "$DIR/go"
    rm -f bench
    go build -o bench . > /dev/null
    [ -f bench ] || { echo "[go] FAILED"; exit 1; }
    BUILT="$BUILT go"
    echo "[go] ok"
fi

# Rust
if [ -d "$DIR/rust" ]; then
    echo "[rust] building..."
    cd "$DIR/rust"
    rm -rf target
    cargo build --release > /dev/null 2>&1
    [ -f target/release/bench ] || { echo "[rust] FAILED"; exit 1; }
    BUILT="$BUILT rust"
    echo "[rust] ok"
fi

# Python and JS — no build step
[ -d "$DIR/python" ] && { BUILT="$BUILT python"; echo "[python] interpreted, no build"; }
[ -d "$DIR/javascript" ] && { BUILT="$BUILT javascript"; echo "[javascript] interpreted, no build"; }

cd "$ROOT"
if [ -z "$BUILT" ]; then
    echo "$WL has no implementation directories — nothing was built" >&2
    exit 1
fi
echo "build complete: $WL —$BUILT"
