#!/usr/bin/env sh
# collapse-recursion numacc race — builds THIS dir's input.k twice:
#   collapsed   — default build, the C3 numacc family fires on both arms
#   uncollapsed — KORU_COLLAPSE_OFF=1, the source runs as written
# Both arms step n = 10,100,1000,10000,65536 with in-process timing
# (std/time). The uncollapsed leg is the slow one by design: fibn ~40s,
# lrec (25k digits at n=65536) ~2min in ReleaseFast. The collapsed leg
# prints the same table in milliseconds.
#
# Usage: ./run.sh [mode]    default ReleaseFast
# Env: KORUC, KORU_STDLIB default to the repo. On glibc-2.31 hosts set
# KORU_BACKEND_TARGET=x86_64-linux-gnu.2.31 (or the zig-koru-231 shim).
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO="$ROOT/../../.."
KORUC="${KORUC:-$REPO/zig-out/bin/koruc}"
export KORU_STDLIB="${KORU_STDLIB:-$REPO/koru_std}"
MODE="${1:-ReleaseFast}"

[ -x "$KORUC" ] || { echo "koruc not built at $KORUC" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$ROOT/input.k" "$work/"

(cd "$work" && "$KORUC" "-O$MODE" input.k >/dev/null && mv a.out a_collapsed)
(cd "$work" && KORU_COLLAPSE_OFF=1 "$KORUC" "-O$MODE" input.k >/dev/null && mv a.out a_uncollapsed)

echo "=== collapsed (C3 numacc fires) ==="
"$work/a_collapsed"
echo "=== uncollapsed (KORU_COLLAPSE_OFF=1) ==="
"$work/a_uncollapsed"
