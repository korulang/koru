#!/usr/bin/env sh
# One Koru source, compiled to both targets, against a hand-written JavaScript
# control. Correctness is all three checksums agreeing; the timing is the point.
#
# The arms are built in their own temp directories because koruc writes
# build.zig and output_emitted.* into its working directory — the same reason
# 004_grid_layout does it — and because the Zig and JS builds of THIS file would
# otherwise clobber each other's generated artifacts.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
KORUC="${KORUC:-$ROOT/../../../zig-out/bin/koruc}"
export KORU_STDLIB="${KORU_STDLIB:-$ROOT/../../../koru_std}"

if [ ! -x "$KORUC" ]; then
    echo "koruc not built at $KORUC — run 'zig build' first" >&2
    exit 1
fi
if ! command -v node >/dev/null 2>&1; then
    echo "node not found; the JavaScript arms cannot run" >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$ROOT/ecs_integration.k" "$work/zig_arm.k"
mkdir -p "$work/js"
cp "$ROOT/ecs_integration.k" "$work/js/js_arm.k"

( cd "$work" && "$KORUC" zig_arm.k >/dev/null 2>&1 )
( cd "$work/js" && "$KORUC" js_arm.k --lang=js >/dev/null 2>&1 )

# Every arm reports `checksum <n>`. They are compared below rather than eyeballed
# — a benchmark whose arms compute different things measures nothing, and that
# failure is silent unless something checks.
run_arm() {
    label="$1"
    outfile="$work/$2.txt"
    shift 2
    printf '%-22s ' "$label"
    { /usr/bin/time -p "$@" >"$outfile"; } 2>&1 | awk '/real/{printf "%6ss   ", $2}'
    cat "$outfile"
}

echo
echo "  4096 entities x 50000 frames, two columns written per row"
echo
run_arm "koru -> zig"          zig  "$work/a.out"
run_arm "koru -> js"           js   node "$work/js/output_emitted.js"
run_arm "hand-written js"      ctl  node "$ROOT/control.js"
echo

z="$(cat "$work/zig.txt")"
j="$(cat "$work/js.txt")"
c="$(cat "$work/ctl.txt")"
if [ "$z" != "$j" ] || [ "$z" != "$c" ]; then
    echo "CHECKSUM MISMATCH — the arms are not computing the same thing:" >&2
    echo "  koru -> zig      $z" >&2
    echo "  koru -> js       $j" >&2
    echo "  hand-written js  $c" >&2
    exit 1
fi
echo "  all three arms agree: $z"
