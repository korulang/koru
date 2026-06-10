#!/usr/bin/env bash
# build.sh <workload>  — builds all language implementations of a workload
set -e
WL="$1"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/workloads/$WL"
[ -d "$DIR" ] || { echo "workload not found: $WL"; exit 1; }

# Koru
if [ -d "$DIR/koru" ]; then
    echo "[koru] building..."
    cd "$DIR/koru"
    rm -rf zig-out .zig-cache backend.zig build.zig build_backend.zig backend_output_emitted.zig output_emitted.zig build_output.zig build.zig.zon a.out
    KORU_STDLIB=/Users/larsde/src/koru/koru_std KORU_PATH=/Users/larsde/src/koru-libs /Users/larsde/src/koru/zig-out/bin/koruc input.kz -o backend.zig > /dev/null
    zig build -Doptimize=ReleaseFast > /dev/null
    ./zig-out/bin/backend > /dev/null
    [ -f a.out ] || { echo "[koru] FAILED to build a.out"; exit 1; }
    echo "[koru] ok"
fi

# C#
if [ -d "$DIR/csharp" ]; then
    echo "[csharp] building..."
    cd "$DIR/csharp"
    rm -rf out bin obj
    dotnet publish -c Release --self-contained false -o out > /dev/null 2>&1
    [ -f out/bench.dll ] || { echo "[csharp] FAILED"; exit 1; }
    echo "[csharp] ok"
fi

# Go
if [ -d "$DIR/go" ]; then
    echo "[go] building..."
    cd "$DIR/go"
    rm -f bench
    go build -o bench . > /dev/null
    [ -f bench ] || { echo "[go] FAILED"; exit 1; }
    echo "[go] ok"
fi

# Rust
if [ -d "$DIR/rust" ]; then
    echo "[rust] building..."
    cd "$DIR/rust"
    rm -rf target
    cargo build --release > /dev/null 2>&1
    [ -f target/release/bench ] || { echo "[rust] FAILED"; exit 1; }
    echo "[rust] ok"
fi

# Python and JS — no build step
[ -d "$DIR/python" ] && echo "[python] interpreted, no build"
[ -d "$DIR/javascript" ] && echo "[javascript] interpreted, no build"

cd "$ROOT"
echo "build complete: $WL"
