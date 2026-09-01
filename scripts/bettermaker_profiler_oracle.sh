#!/usr/bin/env bash
# Bettermaker oracle: profiler toolchain join control set (+ optional scale probe).
# Exit 0 = all requested gates passed. Non-zero = first failure wins.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONTROLS=(
    511_profiler_plural_store
    510_profiler_end_to_end
    420_003_profiler_loop
    690_121_twenty_six_component_stores
)

RUN_SCALE=false
PROBE=""
KORUC="${KORUC:-$ROOT/zig-out/bin/koruc}"

usage() {
    cat <<'EOF'
Usage: ./scripts/bettermaker_profiler_oracle.sh [--scale] [--probe path.kz]

  default     Run profiler regression control set (4 tests)
  --scale     Also compile/run examples/profiler_scale.kz and check trace stats
  --probe P   Compile P with --profile, build in /tmp, run output binary once

Gates:
  - no live regression/zig build (pgrep)
  - regression controls pass (Running N tests == N)
  - scale: >= 50 transition bars, 0 write-* self-obs, JSON closed
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scale) RUN_SCALE=true; shift ;;
        --probe)
            PROBE="${2:?--probe requires a path}"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if pgrep -fl "run_regression|zig build" >/dev/null 2>&1; then
    echo "FAIL: live regression or zig build detected — wait or stop it first" >&2
    pgrep -fl "run_regression|zig build" >&2 || true
    exit 1
fi

if [[ ! -x "$KORUC" ]]; then
    echo "FAIL: koruc not found at $KORUC — run zig build first" >&2
    exit 1
fi

echo "== profiler oracle: regression controls (${#CONTROLS[@]} tests) =="
OUT="$("$ROOT/run_regression.sh" "${CONTROLS[@]}" 2>&1)" || {
    echo "$OUT"
    echo "FAIL: regression controls" >&2
    exit 1
}
echo "$OUT" | tail -8

RUNNING=$(echo "$OUT" | sed -n 's/^Running \([0-9]*\) tests\.\.\./\1/p' | tail -1)
if [[ "${RUNNING:-0}" != "${#CONTROLS[@]}" ]]; then
    echo "FAIL: asked ${#CONTROLS[@]} tests, harness reported Running ${RUNNING:-?} tests" >&2
    exit 1
fi

if echo "$OUT" | grep -q "❌\|FAILED TESTS\|Some tests failed"; then
    echo "FAIL: regression reported failures" >&2
    exit 1
fi

echo "PASS: regression controls (${#CONTROLS[@]}/${#CONTROLS[@]})"

run_scale_probe() {
    local scale="$ROOT/examples/profiler_scale.kz"
    local work=/tmp/koru-bettermaker-profiler-scale
    rm -rf "$work"
    mkdir -p "$work"

    echo "== profiler oracle: scale probe ($scale) =="
    rm -f /tmp/koru_profile.json
    "$KORUC" "$scale" -o "$work/backend.zig" --profile >/dev/null

    ( cd "$work" && zig build -Doptimize=ReleaseFast >/dev/null )
    ( cd "$work" && ./zig-out/bin/backend output >/dev/null )
    ( cd "$work" && ./output >/dev/null )

    if [[ ! -f /tmp/koru_profile.json ]]; then
        echo "FAIL: scale probe — no /tmp/koru_profile.json" >&2
        exit 1
    fi

    python3 - <<'PY' || exit 1
import json, sys
with open("/tmp/koru_profile.json") as f:
    data = json.load(f)
events = data["traceEvents"]
trans = [e for e in events if e.get("cat") == "transition" and e.get("ph") == "X"]
self_obs = [e for e in events if "write-" in e.get("name", "")]
raw = open("/tmp/koru_profile.json").read().rstrip()
if len(trans) < 50:
    print(f"FAIL: scale probe — {len(trans)} transition bars (want >= 50)", file=sys.stderr)
    sys.exit(1)
if self_obs:
    print(f"FAIL: scale probe — profiler self-observation: {self_obs}", file=sys.stderr)
    sys.exit(1)
if not raw.endswith("]}"):
    print("FAIL: scale probe — JSON not closed", file=sys.stderr)
    sys.exit(1)
print(f"PASS: scale probe — {len(trans)} transition bars, 0 self-obs, JSON closed")
PY
}

run_probe() {
    local input="$1"
    local work=/tmp/koru-bettermaker-profiler-probe
    rm -rf "$work"
    mkdir -p "$work"

    echo "== profiler oracle: probe ($input) =="
    rm -f /tmp/koru_profile.json
    if ! "$KORUC" "$input" -o "$work/backend.zig" --profile 2>"$work/compile.err"; then
        echo "FAIL: probe compile/backend" >&2
        cat "$work/compile.err" >&2
        exit 1
    fi
    ( cd "$work" && zig build -Doptimize=ReleaseFast >/dev/null )
    ( cd "$work" && ./zig-out/bin/backend output >/dev/null )
    ( cd "$work" && ./output >/dev/null )
    echo "PASS: probe compiled and ran"
}

if $RUN_SCALE; then
    run_scale_probe
fi

if [[ -n "$PROBE" ]]; then
    run_probe "$PROBE"
fi

echo "== profiler oracle: ALL GATES PASSED =="
