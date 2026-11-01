#!/usr/bin/env sh
# qcalc race — drives examples/qcalc/qcalc.k with random quantity lines and
# checks every output against an exact Fraction oracle (race.py): add/sub/mul
# must match exactly, div to 23 significant digits (qcalc divides at prec 25),
# dim-mismatch and div-zero must refuse by name. Reports throughput per line.
#
# Usage: ./run.sh [lines] [seed] [mode]    default 20000 7 ReleaseFast
# Env: KORUC, KORU_STDLIB default to the repo. On glibc-2.31 hosts set
# KORU_ZIG to the zig-koru-231 shim and put a `zig` symlink to it on PATH.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO="$ROOT/../../.."
KORUC="${KORUC:-$REPO/zig-out/bin/koruc}"
export KORU_STDLIB="${KORU_STDLIB:-$REPO/koru_std}"
N="${1:-20000}"
SEED="${2:-7}"
MODE="${3:-ReleaseFast}"

command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }
[ -x "$KORUC" ] || { echo "koruc not built at $KORUC" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$REPO/examples/qcalc/qcalc.k" "$work/"
(cd "$work" && "$KORUC" "-O$MODE" qcalc.k >/dev/null)
QCALC="$work/a.out" python3 "$ROOT/race.py" "$N" "$SEED"
