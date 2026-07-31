#!/usr/bin/env bash
# wall_check.sh — the wall census, derived rather than written.
#
# A wall is a rule compiled into the harness so nobody has to remember it. The
# failure mode of walls is being FORGOTTEN: regression_lib.sh:608 was built,
# held the negative corpus at 223/227, and was then measured against twice with
# the wrong predicate because nobody knew it existed. A prose inventory of walls
# rots on the same clock. So the inventory here is DERIVED: this check extracts
# the harness's live guard surface from its sources and diffs it against the
# registered rows in scripts/WALLS.md — the same manifest+extractor shape as
# prose_check.sh check D and registry_check.zig.
#
# Three drifts fire (exit 1):
#   UNREGISTERED   — a guard exists in the harness with no row in WALLS.md.
#                    Someone built a wall; register it so it cannot be forgotten.
#   STALE          — a row in WALLS.md names a guard the harness no longer has.
#                    Someone removed a wall; either restore it or retire the row
#                    in writing.
#   MISSING-ANCHOR — an anchored wall's identifying text is gone from its file.
#                    The wall may have been reworded (update the anchor) or
#                    deleted (see STALE).
#
# What is extracted, and from where:
#   verdict:* — every literal a harness script can write into a test's FAILURE
#               file (echo "..." > "$test_dir/FAILURE" and the _js_equiv_fail
#               call sites). Dynamic tails normalize to a family key ("leak-*").
#               This set is COMPLETE over per-test verdicts by construction.
#   check:*   — the lettered checks of prose_check.sh and the three buckets of
#               registry_check.zig, read from their sources.
#   anchor:*  — guards with no verdict of their own (runner refusals, locks,
#               sub-walls sharing a verdict, walls spelled as tests). Each row
#               names a file and a literal that must still be present (or
#               EXISTS for path presence).
#
# NOT covered, on purpose: accidental walls — an assertion that exists, works,
# and was written by nobody (395_010's unguarded union read). There is no bulk
# detector for that species; pretending otherwise would be a lie in the one
# place that must not lie.
#
# Run from anywhere: bash scripts/wall_check.sh
set -o pipefail
cd "$(dirname "$0")/.."
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
MANIFEST="scripts/WALLS.md"
fail=0

if [ ! -f "$MANIFEST" ]; then
    echo -e "${RED}wall-check FAILED${NC} — manifest $MANIFEST is missing"
    exit 1
fi

HARNESS_FILES=(scripts/regression_lib.sh run_single_test.sh run_regression.sh)

extract_verdicts() {
    {
        grep -hoE 'echo "[^"]+" > "\$(test_dir|tdir)/FAILURE"' "${HARNESS_FILES[@]}" 2>/dev/null \
            | sed -E 's/^echo "//; s/" > .*$//'
        # _js_equiv_fail routes its first argument into FAILURE; the call sites
        # carry the literals. Exclude the function's own definition line.
        grep -hE '_js_equiv_fail "[^"]+"' scripts/regression_lib.sh 2>/dev/null \
            | grep -v '_js_equiv_fail()' \
            | sed -E 's/.*_js_equiv_fail "([^"]+)".*/\1/'
    } | while IFS= read -r v; do
        case "$v" in
            '$'*) ;;                              # pure-variable verdict: named at its call sites
            *'$'*) printf '%s*\n' "${v%%\$*}" ;;  # dynamic tail -> family key
            *) printf '%s\n' "$v" ;;
        esac
    done | sort -u
}

extract_checks() {
    {
        grep -oE '^# --- [A-Z]:' scripts/prose_check.sh 2>/dev/null \
            | sed -E 's/^# --- ([A-Z]):/prose-check:\1/'
        grep -qF 'ORPHAN_EMIT (emitted, never declared)' scripts/registry_check.zig 2>/dev/null && echo "registry:ORPHAN_EMIT"
        grep -qF 'DEAD (declared, never emitted'         scripts/registry_check.zig 2>/dev/null && echo "registry:DEAD"
        grep -qF 'ROTTEN_PIN (pinned by a test'          scripts/registry_check.zig 2>/dev/null && echo "registry:ROTTEN_PIN"
    } | sort -u
}

LIVE=$(mktemp "${TMPDIR:-/tmp}/koru-wallcheck-live.XXXXXX")
REG=$(mktemp "${TMPDIR:-/tmp}/koru-wallcheck-reg.XXXXXX")
trap 'rm -f "$LIVE" "$REG"' EXIT

{ extract_verdicts | sed 's/^/verdict:/'; extract_checks; } | sort -u > "$LIVE"

grep -E '^\| *(verdict:|prose-check:|registry:)' "$MANIFEST" \
    | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}' | sort -u > "$REG"

echo "wall-check — the guard surface vs its register (scripts/WALLS.md)"
echo "  live guards: $(wc -l < "$LIVE" | tr -d ' ')  registered: $(wc -l < "$REG" | tr -d ' ')"

UNREG=$(comm -23 "$LIVE" "$REG")
STALE=$(comm -13 "$LIVE" "$REG")

if [ -n "$UNREG" ]; then
    echo -e "  ${RED}✗ UNREGISTERED${NC} — guard(s) in the harness with no row in $MANIFEST:"
    printf '%s\n' "$UNREG" | sed 's/^/      /'
    echo "      A wall nobody registered is a wall everyone forgets. Add a row:"
    echo "      | <id> | <where it lives> | <what it guards> | <the mirror it does not cover> |"
    fail=1
fi
if [ -n "$STALE" ]; then
    echo -e "  ${RED}✗ STALE${NC} — row(s) in $MANIFEST naming a guard the harness no longer has:"
    printf '%s\n' "$STALE" | sed 's/^/      /'
    echo "      Either the wall was removed (restore it, or retire the row in writing)"
    echo "      or it was renamed (update the row to the new id)."
    fail=1
fi
if [ -z "$UNREG" ] && [ -z "$STALE" ]; then
    echo -e "  ${GREEN}✓${NC} verdicts + checks: register matches the extracted surface"
fi

# --- anchors -----------------------------------------------------------------
ANCHOR_FAILS=""
while IFS='|' read -r _ id file lit _; do
    id=$(echo "$id" | sed -E 's/^ +| +$//g')
    file=$(echo "$file" | sed -E 's/^ +| +$//g; s/^`|`$//g')
    lit=$(echo "$lit" | sed -E 's/^ +| +$//g; s/^`|`$//g')
    [ -n "$id" ] || continue
    if [ "$lit" = "EXISTS" ]; then
        if [ ! -e "$file" ]; then
            ANCHOR_FAILS="${ANCHOR_FAILS}      ${id}: path gone: ${file}"$'\n'
        fi
    else
        if ! grep -qF -- "$lit" "$file" 2>/dev/null; then
            ANCHOR_FAILS="${ANCHOR_FAILS}      ${id}: '${lit}' not found in ${file}"$'\n'
        fi
    fi
done < <(grep -E '^\| *anchor:' "$MANIFEST")

N_ANCHORS=$(grep -cE '^\| *anchor:' "$MANIFEST")
if [ -z "$ANCHOR_FAILS" ]; then
    echo -e "  ${GREEN}✓${NC} anchors: all ${N_ANCHORS} anchored walls still present"
else
    echo -e "  ${RED}✗ MISSING-ANCHOR${NC} — anchored wall(s) whose identifying text is gone:"
    printf '%s' "$ANCHOR_FAILS"
    echo "      Reworded wall -> update the anchor literal in $MANIFEST."
    echo "      Removed wall  -> restore it, or retire the row in writing."
    fail=1
fi

echo ""
if [ "$fail" -ne 0 ]; then
    echo -e "${RED}wall-check FAILED${NC} — the guard surface drifted from its register"
    exit 1
fi
echo -e "${GREEN}wall-check OK${NC} (every guard registered, every registered guard present)"
