#!/usr/bin/env sh
# std/num vs bc vs python3 decimal — arbitrary-precision race.
#
# Three arms, same operands, same significant-digit targets:
#   koru   — this dir's input.k, built Debug then ReleaseFast; each op is
#            timed in-process via std/time:now/report (stderr).
#   bc     — one wN.bc script per workload, whole-process timing.
#   python — bench.py: C decimal for the core ops; exp/ln/sin/atan are
#            Taylor series written in-script (py3.8 decimal has none);
#            int arms for the exact ops (reference-grade bigint).
#
# Env: KORUC, KORU_STDLIB default to the repo; ZIG names the zig to drive
# (on glibc-2.31 hosts point it at the zig-koru-231 shim AND put a `zig`
# symlink to it earlier in PATH — the emitted backend shells out to `zig`
# when it compiles a.out).
set -u

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO="$ROOT/../../.."
KORUC="${KORUC:-$REPO/zig-out/bin/koruc}"
ZIG="${ZIG:-zig}"
export KORU_STDLIB="${KORU_STDLIB:-$REPO/koru_std}"

command -v bc >/dev/null || { echo "bc not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }
[ -x "$KORUC" ] || { echo "koruc not built at $KORUC" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$ROOT"/input.k "$ROOT"/w*.bc "$ROOT"/bench.py "$ROOT"/compare.py \
   "$ROOT"/operands.py "$work/"
cd "$work"

echo "== koru: emit + build backend =="
"$KORUC" input.k -o backend.zig --release=fast > koruc.log 2>&1 || {
    echo "koruc failed"; tail -20 koruc.log; exit 1; }
"$ZIG" build --build-file build_backend.zig > zig.log 2>&1 || {
    echo "zig build failed"; tail -20 zig.log; exit 1; }

# backend emits output_emitted.zig and compiles a.out (mode from
# compiler_env.json — ReleaseFast here).
./zig-out/bin/backend > backend.log 2>&1 || {
    echo "backend emit failed"; tail -20 backend.log; exit 1; }
[ -x ./a.out ] || { echo "backend produced no a.out"; exit 1; }

echo "== koru: ReleaseFast run =="
./a.out > koru.out 2> koru.time
cat koru.time

echo "== bc =="
for w in w1 w2 w3 w4 w5 w6 w7 w8 w9 w10; do
    t0=$(date +%s%N)
    bc -l "$w.bc" > "$w.bc.out"
    t1=$(date +%s%N)
    echo "BC $w: $(( (t1 - t0) / 1000000 ))ms" | tee -a bc.time
done

echo "== python3 decimal =="
python3 bench.py > py.out 2> py.time
cat py.time

echo "== digit agreement =="
python3 compare.py
