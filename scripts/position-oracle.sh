#!/bin/bash
# Differential position-agnosticism oracle for the Koru regression suite.
#
# Question answered, mechanically, per eligible passing test: does the program
# behave identically when its final top-level invocation flow is transplanted
# into a nested continuation position?
#
# Method (no compile pipeline is reimplemented — every run goes through
# ./run_single_test.sh, the same per-test entry point run_regression.sh
# --parallel uses):
#   1. Enumerate MUST_RUN tests; keep only those whose input.kz ends in a
#      single transplantable top-level invocation flow (conservative filter,
#      every skip reported with its reason — scripts/position_oracle_gen.py).
#   2. Run the ORIGINAL live. Disk SUCCESS/FAILURE markers are never trusted.
#      A live-failing original is reported ORIGINAL-RED and not investigated.
#   3. Generate the nested twin mechanically: the verbatim void-event scaffold
#      from 210_045 (renamed position-oracle-setup) + `~setup() |> X(args)` +
#      original continuation lines indented one level. The twin's expected
#      output is the original's FRESHLY OBSERVED actual.txt, never the
#      checked-in expected.txt.
#   4. Run the twin through the same harness machinery; diff observed vs
#      expected. TWIN-FAIL rows are position-dependence findings — they are
#      reported, never fixed here.
#
# Twins are generated under tests/regression/999_POSITION_ORACLE (created by
# this run, removed afterwards unless --keep-twins; the script refuses to
# start if that directory already exists — it never deletes anything it did
# not create this run). No snapshot is written (run_single_test.sh does not
# touch test-results/).
#
# Usage:
#   ./scripts/position-oracle.sh [--no-rebuild] [--max N] [--all] [--keep-twins] [name-filter ...]
#
#   --no-rebuild   skip `zig build` (rapid iteration)
#   --max N        cap the sample at N eligible tests (default 45),
#                  round-robin across subclusters for spread
#   --all          no cap: every eligible test
#   --keep-twins   leave tests/regression/999_POSITION_ORACLE in place
#   name-filter    only consider test dirs whose basename contains the filter

set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$ROOT" || exit 1

export KORU_STDLIB="$ROOT/koru_std"
export KORU_PATH="$ROOT"

GEN="$SCRIPT_DIR/position_oracle_gen.py"
SCRATCH="tests/regression/999_POSITION_ORACLE"
REPORT="$ROOT/position-oracle-report.txt"
SENTINEL_TEST="tests/regression/200_COMPILER_FEATURES/210_PARSER/210_045_source_block_in_pipeline"

REBUILD=true
MAX_SAMPLE=45
KEEP_TWINS=false
FILTERS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --no-rebuild) REBUILD=false ;;
        --max) shift; MAX_SAMPLE="$1" ;;
        --all) MAX_SAMPLE=0 ;;
        --keep-twins) KEEP_TWINS=true ;;
        *) FILTERS+=("$1") ;;
    esac
    shift
done

# ── Scratch cluster: refuse to reuse, only delete what this run created ──────
if [ -e "$SCRATCH" ]; then
    echo "ERROR: $SCRATCH already exists. This script only deletes directories" >&2
    echo "it created itself this run — remove or rename it manually, then rerun." >&2
    exit 1
fi
mkdir -p "$SCRATCH"
CREATED_SCRATCH=true
cleanup_scratch() {
    if [ "$CREATED_SCRATCH" = true ] && [ "$KEEP_TWINS" = false ]; then
        rm -rf "$ROOT/$SCRATCH"
    fi
}
trap cleanup_scratch EXIT

# ── Build the compiler (the suite default), sanity-check the harness ─────────
if [ "$REBUILD" = true ]; then
    echo "Building compiler (zig build)..."
    if ! zig build; then
        echo "ERROR: zig build failed — cannot run the oracle." >&2
        exit 1
    fi
fi

echo "Sanity check: running $SENTINEL_TEST live..."
if ! REGRESSION_QUIET=true ./run_single_test.sh "$SENTINEL_TEST" >/dev/null; then
    echo "ERROR: sentinel test 210_045 fails live — harness or compiler is not" >&2
    echo "healthy in this tree; refusing to interpret oracle results." >&2
    exit 1
fi
echo "Sanity check passed."
echo ""

# ── Enumerate + filter ────────────────────────────────────────────────────────
ELIGIBLE_FILE=$(mktemp /tmp/position-oracle-eligible.XXXXXX)
SKIPPED_FILE=$(mktemp /tmp/position-oracle-skipped.XXXXXX)
SAMPLE_FILE=$(mktemp /tmp/position-oracle-sample.XXXXXX)
EXCLUDED_FILE=$(mktemp /tmp/position-oracle-excluded.XXXXXX)
cleanup_tmp() { rm -f "$ELIGIBLE_FILE" "$SKIPPED_FILE" "$SAMPLE_FILE" "$EXCLUDED_FILE"; cleanup_scratch; }
trap cleanup_tmp EXIT

TOTAL_MUST_RUN=0
while IFS= read -r marker; do
    dir=$(dirname "$marker")
    case "$dir" in
        */_archive/*|*/openspec-archive/*|"$SCRATCH"/*) continue ;;
    esac
    name=$(basename "$dir")
    if [ ${#FILTERS[@]} -gt 0 ]; then
        matched=false
        for f in "${FILTERS[@]}"; do
            case "$name" in *"$f"*) matched=true ;; esac
        done
        [ "$matched" = true ] || continue
    fi
    TOTAL_MUST_RUN=$((TOTAL_MUST_RUN + 1))
    verdict=$(python3 "$GEN" check "$dir")
    if [ "$verdict" = "OK" ]; then
        echo "$dir" >> "$ELIGIBLE_FILE"
    else
        echo "$dir ${verdict#SKIP:}" >> "$SKIPPED_FILE"
    fi
done < <(find tests/regression -name MUST_RUN -type f | sort)

ELIGIBLE_COUNT=$(wc -l < "$ELIGIBLE_FILE" | tr -d ' ')
SKIPPED_COUNT=$(wc -l < "$SKIPPED_FILE" | tr -d ' ')

# ── Sample: round-robin across subclusters for spread ─────────────────────────
python3 - "$ELIGIBLE_FILE" "$SAMPLE_FILE" "$EXCLUDED_FILE" "$MAX_SAMPLE" <<'EOF'
import sys
from collections import OrderedDict

eligible_path, sample_path, excluded_path, cap = sys.argv[1:5]
cap = int(cap)
dirs = [l.strip() for l in open(eligible_path) if l.strip()]
groups = OrderedDict()
for d in sorted(dirs):
    parts = d.split("/")
    # group by subcluster: tests/regression/<A>/<B>/<test> -> A/B,
    # tests/regression/<A>/<test> -> A
    key = "/".join(parts[2:-1])
    groups.setdefault(key, []).append(d)

sample = []
if cap <= 0:
    sample = sorted(dirs)
else:
    i = 0
    while len(sample) < cap and any(len(v) > i for v in groups.values()):
        for v in groups.values():
            if i < len(v) and len(sample) < cap:
                sample.append(v[i])
        i += 1

chosen = set(sample)
with open(sample_path, "w") as f:
    for d in sorted(sample):
        f.write(d + "\n")
with open(excluded_path, "w") as f:
    for d in sorted(dirs):
        if d not in chosen:
            f.write(d + "\n")
EOF

SAMPLE_COUNT=$(wc -l < "$SAMPLE_FILE" | tr -d ' ')
EXCLUDED_COUNT=$(wc -l < "$EXCLUDED_FILE" | tr -d ' ')

# ── Run originals + twins ─────────────────────────────────────────────────────
MATRIX=""
DETAILS=""
N_TWIN_PASS=0
N_TWIN_FAIL=0
N_ORIGINAL_RED=0

add_row() { MATRIX="${MATRIX}$1
"; }

idx=0
while IFS= read -r dir; do
    idx=$((idx + 1))
    name=$(basename "$dir")
    echo "[$idx/$SAMPLE_COUNT] $name"

    echo "  original: running live..."
    if ! REGRESSION_QUIET=true ./run_single_test.sh "$dir" >/dev/null; then
        reason=$(head -1 "$dir/FAILURE" 2>/dev/null || echo "unknown")
        echo "  original: RED ($reason)"
        add_row "ORIGINAL-RED  $name  ($reason)  [$dir]"
        N_ORIGINAL_RED=$((N_ORIGINAL_RED + 1))
        continue
    fi
    if [ ! -f "$dir/actual.txt" ]; then
        echo "  original: passed but left no actual.txt — treating as ORIGINAL-RED (no observed output)"
        add_row "ORIGINAL-RED  $name  (no-observed-output)  [$dir]"
        N_ORIGINAL_RED=$((N_ORIGINAL_RED + 1))
        continue
    fi

    twin="$SCRATCH/$name"
    rm -rf "$twin"
    cp -R "$dir" "$twin"
    # Strip generated artifacts and markers from the twin copy (same list the
    # harness itself cleans before a run, plus result markers).
    rm -f "$twin/SUCCESS" "$twin/FAILURE" "$twin/PRIORITY" "$twin/.cache-fingerprint" \
          "$twin/actual.txt" "$twin/actual.json" "$twin/ast.err" \
          "$twin/backend.zig" "$twin/backend" "$twin/backend.err" "$twin/backend.out" \
          "$twin/backend_output_emitted.zig" "$twin/build_backend.zig" "$twin/build.zig" \
          "$twin/temp_build.zig" "$twin/compile_backend.err" "$twin/compile_kz.err" \
          "$twin/compiler_env.zig" "$twin/program_ast.zig" "$twin/output" \
          "$twin/output_emitted.zig" "$twin/post.log" "$twin/expected_patterns.txt"
    rm -rf "$twin/zig-out" "$twin/.zig-cache"

    if ! python3 "$GEN" rewrite "$dir/input.kz" > "$twin/input.kz"; then
        echo "  twin: GENERATOR ERROR — oracle bug, aborting" >&2
        exit 1
    fi
    # Twin's expected output = the original's freshly observed live output.
    cp "$dir/actual.txt" "$twin/expected.txt"

    echo "  twin: running live..."
    if REGRESSION_QUIET=true ./run_single_test.sh "$twin" >/dev/null; then
        echo "  twin: PASS"
        add_row "TWIN-PASS     $name  [$dir]"
        N_TWIN_PASS=$((N_TWIN_PASS + 1))
        rm -rf "$twin"
    else
        stage=$(head -1 "$twin/FAILURE" 2>/dev/null || echo "unknown")
        echo "  twin: FAIL ($stage)"
        add_row "TWIN-FAIL     $name  (stage: $stage)  [$dir]"
        N_TWIN_FAIL=$((N_TWIN_FAIL + 1))
        DETAILS="${DETAILS}
──────────────────────────────────────────────────────────────────
TWIN-FAIL $name   (stage: $stage)
original: $dir
"
        if [ "$stage" = "output" ] && [ -f "$twin/actual.txt" ]; then
            DETAILS="${DETAILS}output diff (expected = original's live output / actual = twin):
$(diff -u "$twin/expected.txt" "$twin/actual.txt" | head -30)
"
        else
            for errfile in compile_kz.err compile_backend.err backend.err; do
                if [ -s "$twin/$errfile" ]; then
                    DETAILS="${DETAILS}first lines of $errfile:
$(grep -v "^\s*$" "$twin/$errfile" | head -8)
"
                    break
                fi
            done
        fi
        DETAILS="${DETAILS}twin source ($twin/input.kz):
$(cat "$twin/input.kz")
"
    fi
done < "$SAMPLE_FILE"

# ── Report ────────────────────────────────────────────────────────────────────
{
    echo "════════════════════════════════════════════════════════════════════"
    echo "  POSITION-AGNOSTICISM ORACLE REPORT"
    echo "════════════════════════════════════════════════════════════════════"
    echo "generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "HEAD:      $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo ""
    echo "Question per test: does the program behave identically when its final"
    echo "top-level invocation flow is transplanted into a nested continuation"
    echo "position (~position-oracle-setup() |> X(...), the 210_045 scaffold)?"
    echo ""
    echo "MUST_RUN tests considered: $TOTAL_MUST_RUN"
    echo "  eligible (transplantable):   $ELIGIBLE_COUNT"
    echo "  skipped by filter:           $SKIPPED_COUNT (every one listed below)"
    echo "  sampled this run:            $SAMPLE_COUNT (cap: ${MAX_SAMPLE:-none}; round-robin across subclusters)"
    echo "  eligible but excluded by cap: $EXCLUDED_COUNT (listed below)"
    echo ""
    echo "── MATRIX ────────────────────────────────────────────────────────────"
    printf '%s' "$MATRIX"
    echo ""
    echo "── SUMMARY ───────────────────────────────────────────────────────────"
    echo "TWIN-PASS:    $N_TWIN_PASS"
    echo "TWIN-FAIL:    $N_TWIN_FAIL   <-- each is a position-dependence finding"
    echo "ORIGINAL-RED: $N_ORIGINAL_RED"
    echo ""
    if [ -n "$DETAILS" ]; then
        echo "── TWIN-FAIL DETAILS ─────────────────────────────────────────────────"
        printf '%s\n' "$DETAILS"
    fi
    echo "── ELIGIBLE BUT EXCLUDED BY SAMPLE CAP ───────────────────────────────"
    if [ -s "$EXCLUDED_FILE" ]; then cat "$EXCLUDED_FILE"; else echo "(none)"; fi
    echo ""
    echo "── SKIPPED TESTS (reason per test, no silent truncation) ─────────────"
    if [ -s "$SKIPPED_FILE" ]; then cat "$SKIPPED_FILE"; else echo "(none)"; fi
} | tee "$REPORT"

echo ""
echo "Report written to $REPORT"
