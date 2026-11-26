#!/usr/bin/env sh
# linalg engine race — bareiss `solve` vs p-adic `solve-dixon` on the same
# exact system: A_k = A0^(2^k), b = A_k * ones (x = ones), det doubling its
# digit width every round. Builds input.k once, runs a.out N times, and
# reports the per-round ms for both engines.
#
# Usage: ./run.sh [runs] [mode]       default 3 ReleaseFast
# Env: KORUC, KORU_STDLIB default to the repo. On glibc-2.31 hosts export
# KORU_BACKEND_TARGET=x86_64-linux-gnu.2.31 first.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO="$ROOT/../../.."
KORUC="${KORUC:-$REPO/zig-out/bin/koruc}"
export KORU_STDLIB="${KORU_STDLIB:-$REPO/koru_std}"
RUNS="${1:-3}"
MODE="${2:-ReleaseFast}"

[ -x "$KORUC" ] || { echo "koruc not built at $KORUC" >&2; exit 1; }
[ -f "$ROOT/input.k" ] || python3 "$ROOT/gen.py" "$ROOT/input.k"

cd "$ROOT"
"$KORUC" "-O$MODE" input.k > koruc.log 2>&1 || {
    echo "koruc failed"; tail -20 koruc.log; exit 1; }
[ -x ./a.out ] || { echo "no a.out produced"; exit 1; }

i=1
while [ "$i" -le "$RUNS" ]; do
    echo "== run $i =="
    ./a.out | grep 'ms=\|done\|dims\|singular\|open'
    i=$((i + 1))
done
