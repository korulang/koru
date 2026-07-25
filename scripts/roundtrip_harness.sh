#!/usr/bin/env bash
# Canonical-printer round-trip harness.
#
# For every positive regression test (no MUST_ERROR), checks the two-leg
# round-trip contract of `koruc --print`:
#
#   leg 1 (tree):  parse(print(parse(src)))  ==  parse(src)   under --ast-canon
#   leg 2 (bytes): print(parse(print(src)))  ==  print(src)
#
# Every failure is one of two treasures: a printer bug, or a place where the
# language permits two spellings of one tree (a canon signal to triage).
#
# Usage:
#   scripts/roundtrip_harness.sh [filter]     # filter = substring of test path
#   PARALLEL=8 scripts/roundtrip_harness.sh
#
# Output: per-test status lines + summary; failures detailed under
# $REPORT_DIR (default: roundtrip-report/ in the repo root, gitignored-level
# scratch — delete freely).

set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KORUC="$REPO_ROOT/zig-out/bin/koruc"
TESTS_DIR="$REPO_ROOT/tests/regression"
# The report tree must live OUTSIDE the repo: `app/…` import resolution walks
# up from the input file, and a reparse context nested inside the repo resolves
# against repo-level markers instead of its own copied dirs (KORU002 ghosts).
REPORT_DIR="${REPORT_DIR:-${TMPDIR:-/tmp}/koru-roundtrip-report}"
PARALLEL="${PARALLEL:-8}"
FILTER="${1:-}"

[ -x "$KORUC" ] || { echo "koruc not built: $KORUC" >&2; exit 2; }
rm -rf "$REPORT_DIR"
mkdir -p "$REPORT_DIR/failures"

# One test: prints "<status>\t<reason>\t<testpath>" to stdout.
run_one() {
    local dir="$1"
    local rel="${dir#"$TESTS_DIR"/}"
    local name safe work
    safe="$(echo "$rel" | tr '/' '__')"
    work="$REPORT_DIR/work/$safe"

    # Source file: input.kz preferred, input.k accepted, .kjs skipped.
    local src=""
    if [ -f "$dir/input.kz" ]; then src="input.kz";
    elif [ -f "$dir/input.k" ]; then src="input.k";
    else echo -e "skip\tno-input\t$rel"; return; fi

    mkdir -p "$work"

    # Original parse → canon tree. A test that doesn't parse is out of scope
    # (roundtrip is defined over parseable programs).
    if ! (cd "$dir" && "$KORUC" --ast-canon "$src" > "$work/orig.canon" 2> "$work/orig.err"); then
        echo -e "skip\tno-parse\t$rel"; return
    fi

    # Leg 0: print at all.
    if ! (cd "$dir" && "$KORUC" --print "$src" > "$work/print1.kz" 2> "$work/print1.err"); then
        local reason
        reason="$(grep -m1 'unprintable' "$work/print1.err" | sed 's/.*unprintable: //' | tr ' \t' '--')"
        echo -e "fail\tunprintable:${reason:-unknown}\t$rel"; return
    fi

    # Reparse context: a SIBLING of the test dir (same parent, same depth) so
    # every relative resolution — koru.json paths, parent auto-imports,
    # sibling modules — behaves exactly as it does for the original. Holds the
    # test's auxiliary files with the printed source in place of the original.
    # The canonical print is ALWAYS .kz-dialect source (pure-.k is a separate
    # projection facet, not built yet), so the reparse file is input.kz
    # regardless of the source facet — the tree is dialect-neutral and the
    # module name stays "input". Removed after the check.
    local reparse_src="input.kz"
    local ctx="$dir.roundtrip-ctx"
    rm -rf "$ctx"; mkdir -p "$ctx"
    (cd "$dir" && find . -mindepth 1 -maxdepth 1 ! -name "$src" -exec cp -R {} "$ctx/" \;)
    cp "$work/print1.kz" "$ctx/$reparse_src"

    # Leg 1: reparse and compare trees.
    if ! (cd "$ctx" && "$KORUC" --ast-canon "$reparse_src" > "$work/reparse.canon" 2> "$work/reparse.err"); then
        echo -e "fail\treparse-error\t$rel"
        cp "$work/print1.kz" "$REPORT_DIR/failures/$safe.print1.kz" 2>/dev/null
        cp "$work/reparse.err" "$REPORT_DIR/failures/$safe.reparse.err" 2>/dev/null
        rm -rf "$ctx"
        return
    fi
    if ! cmp -s "$work/orig.canon" "$work/reparse.canon"; then
        echo -e "fail\ttree-diff\t$rel"
        cp "$work/print1.kz" "$REPORT_DIR/failures/$safe.print1.kz" 2>/dev/null
        { diff <(python3 -m json.tool "$work/orig.canon") <(python3 -m json.tool "$work/reparse.canon") | head -80; } \
            > "$REPORT_DIR/failures/$safe.tree.diff" 2>/dev/null
        rm -rf "$ctx"
        return
    fi

    # Leg 2: print the print, byte-compare.
    if ! (cd "$ctx" && "$KORUC" --print "$reparse_src" > "$work/print2.kz" 2> "$work/print2.err"); then
        echo -e "fail\tprint2-error\t$rel"; rm -rf "$ctx"; return
    fi
    rm -rf "$ctx"
    if ! cmp -s "$work/print1.kz" "$work/print2.kz"; then
        echo -e "fail\tprint-unstable\t$rel"
        diff "$work/print1.kz" "$work/print2.kz" | head -40 > "$REPORT_DIR/failures/$safe.bytes.diff" 2>/dev/null
        return
    fi

    echo -e "pass\t-\t$rel"
    rm -rf "$work"
}
export -f run_one
export KORUC TESTS_DIR REPORT_DIR

# Positive tests only: MUST_ERROR dirs are negative pins (rejected programs
# have no canonical print).
find "$TESTS_DIR" -mindepth 2 -maxdepth 4 -type d \( -name '_archive' -prune -o -print \) \
    | while read -r d; do
        [ -f "$d/input.kz" ] || [ -f "$d/input.k" ] || continue
        [ -f "$d/MUST_ERROR" ] && continue
        case "$d" in *_archive*|*openspec-archive*) continue;; esac
        [ -n "$FILTER" ] && case "$d" in *"$FILTER"*) ;; *) continue;; esac
        echo "$d"
    done \
    | sort | xargs -P "$PARALLEL" -I{} bash -c 'run_one "$@"' _ {} \
    | tee "$REPORT_DIR/results.tsv" \
    | awk -F'\t' '{ n[$1]++ } END { printf "\n== pass %d / fail %d / skip %d ==\n", n["pass"], n["fail"], n["skip"] }'

echo
echo "== failure breakdown =="
awk -F'\t' '$1=="fail" { n[$2]++ } END { for (r in n) printf "%5d  %s\n", n[r], r }' "$REPORT_DIR/results.tsv" | sort -rn
echo
echo "report: $REPORT_DIR/results.tsv (+ failures/)"
