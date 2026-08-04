#!/usr/bin/env sh
# Build and time both grid layouts on a sweep-dominated shape.
# Correctness is the two totals agreeing; the timing is the point.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
KORUC="${KORUC:-$ROOT/../../../zig-out/bin/koruc}"
export KORU_STDLIB="${KORU_STDLIB:-$ROOT/../../../koru_std}"

for variant in column row; do
    # Build in its own directory: koruc writes build.zig and output_emitted.zig
    # into its working directory, so a shared one would have the two variants
    # clobbering each other's generated files.
    work="$(mktemp -d)"
    cp "$ROOT/sweep_$variant.k" "$work/sw.k"
    ( cd "$work" && "$KORUC" sw.k >/dev/null 2>&1 )
    printf '%-7s ' "$variant"
    { /usr/bin/time -p "$work/a.out" >"$work/out.txt"; } 2>&1 | awk '/real/{printf "%ss  ", $2}'
    tail -1 "$work/out.txt"
    rm -rf "$work"
done
