#!/usr/bin/env bash
# TODO sweep — execute every TODO-marked test and report what has become true.
#
# WHY THIS EXISTS
#
# A `TODO` file makes the harness return before the test is compiled or run, and
# counts it in its own column. So a TODO-marked test cannot flip to green on its
# own: it prints the same 📝 the day its feature ships as the day it was filed,
# and the only thing that ever changes it is a human remembering. The documented
# aspirational workflow — add it failing, it flips when implemented — does not
# work through that marker. This sweep is the missing half: it asks, on demand,
# "has any of this become true while nobody was looking?"
#
# WHY IT READS MARKERS ITSELF RATHER THAN THE SUITE'S TALLY
#
# The TODO rule is implemented in several places. `KORU_RUN_TODO=1` reaches the
# per-test early-out in regression_lib.sh, so the tests really do execute — but
# run_regression.sh's parallel tally checks for the TODO file again and skips the
# verdict the worker just wrote, so the run still reports "N TODO, 0 passed".
# Rather than thread the override through every one of those sites (and change
# how the suite counts, which is load-bearing for the published board), this
# sweep runs the tests and then reads the SUCCESS/FAILURE markers straight from
# the test directories. Nothing here can alter the suite's verdict.
#
# WHY "PASSED" IS NOT THE SAME AS "PROMOTABLE"
#
# Measured 2026-08-04, first run: three TODO tests "passed" and NONE was
# promotable. Two were `MUST_RUN` with no `expected.txt` — which asserts only
# that the binary exited 0 — and both printed the exact error their TODO note
# says they are parked on. The third pinned nothing at all and "passed" by
# compiling. The harness refuses a `MUST_ERROR` that names no diagnostic
# ("it passes on ANY failure", regression_lib.sh) but has no such wall for the
# positive twin, so a bare `MUST_RUN` passes on ANY output. Until that wall
# exists, a sweep that reported bare passes as wins would manufacture three
# false victories on its first run. So this script classifies instead:
# PROMOTABLE means passed AND pins something.
#
# Usage:  scripts/todo_sweep.sh [--keep-markers]
# Exit:   1 if anything is PROMOTABLE (action required), else 0.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

KEEP_MARKERS=false
[ "${1:-}" = "--keep-markers" ] && KEEP_MARKERS=true

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'

mapfile -t TODO_DIRS < <(find tests/regression -name TODO -not -path '*/node_modules/*' \
    | xargs -n1 dirname | sort)

# ── Declared residuals ────────────────────────────────────────────────────────
# The second population, and the reason this sweep is a join rather than a test
# runner. A `TODO` marker lives in a test directory and describes a feature; a
# declaration in todo/todo.kz lives beside the CODE and names the test that
# decides it. Measured 2026-08-11: 128 TODO comments in the tree and 66 parked
# tests, substantially the same residuals recorded twice in two systems that
# could not see each other. Driving only one of them drives half the problem.
#
# The gate refuses a declaration whose witness is missing, absent from the
# corpus, or vacuous. A broken manifest stops the sweep instead of being
# reported as clean — a sweep that greens over an undrivable residual is the
# failure this whole surface exists to prevent.
DECLARED_WITNESSES=()
if [ -f todo/todo.kz ] && [ ! -x zig-out/bin/koruc ]; then
    # A manifest exists and cannot be read. Skipping quietly here would print a
    # sweep that looks complete while checking none of the declarations — a
    # substitute result standing in for a check that never ran, which is the
    # one thing this surface is not allowed to do.
    echo "${RED}${BOLD}todo-sweep: todo/todo.kz exists but there is no compiler at zig-out/bin/koruc.${NC}"
    echo "  The declared residuals cannot be checked, so this sweep would report on"
    echo "  half the problem and not say which half. Run zig build first."
    exit 2
fi
if [ -f todo/todo.kz ]; then
    echo "${BOLD}todo-sweep: checking declared residuals${NC}"
    GATE_OUT=$(cd todo && ../zig-out/bin/koruc todo.kz todo 2>&1)
    GATE_RC=$?
    if [ "$GATE_RC" -ne 0 ]; then
        echo "$GATE_OUT" | sed 's/^/  /'
        echo
        echo "${RED}${BOLD}todo-sweep: the residual manifest is broken — refusing to sweep.${NC}"
        echo "  Fix todo/todo.kz first. A sweep over an undrivable residual reports"
        echo "  nothing and looks like it reported something."
        exit 2
    fi
    mapfile -t DECLARED_WITNESSES < <(echo "$GATE_OUT" \
        | sed -n 's/^ *witness  \([0-9A-Za-z_]*\)$/\1/p' | sort -u)
    # The counts line, not the compiler's own trailer — `tail -1` catches
    # koruc's "✓ todo" and reports nothing about the manifest.
    echo "  $(echo "$GATE_OUT" | grep -E '^[0-9]+ owed' | tail -1), ${#DECLARED_WITNESSES[@]} witness(es) to drive"
    echo
fi

if [ "${#TODO_DIRS[@]}" -eq 0 ] && [ "${#DECLARED_WITNESSES[@]}" -eq 0 ]; then
    echo "todo-sweep: no TODO-marked tests and no declared residuals found."
    exit 0
fi

# A declared residual's witness is usually NOT TODO-marked — it is an ordinary
# test that happens to be red. Fold those in so both populations are driven by
# one run, and remember which dirs came from a declaration: a witness that has
# come true means the residual is DISCHARGED, and the declaration in
# todo/todo.kz plus the comment at its site both have to go.
DECLARED_DIRS=()
for w in ${DECLARED_WITNESSES+"${DECLARED_WITNESSES[@]}"}; do
    wd=$(find tests/regression -type d -name "$w" | head -1)
    [ -z "$wd" ] && continue
    already=false
    for d in ${TODO_DIRS+"${TODO_DIRS[@]}"}; do [ "$d" = "$wd" ] && already=true && break; done
    DECLARED_DIRS+=("$wd")
    [ "$already" = false ] && TODO_DIRS+=("$wd")
done

is_declared() {
    for d in ${DECLARED_DIRS+"${DECLARED_DIRS[@]}"}; do [ "$d" = "$1" ] && return 0; done
    return 1
}

echo "${BOLD}todo-sweep: executing ${#TODO_DIRS[@]} test(s)${NC}"
echo "  (TODO-marked ones are normally skipped before compiling; KORU_RUN_TODO=1 runs them)"
echo

# Remember which dirs already carried a verdict marker so cleanup restores
# exactly the prior state rather than blanket-deleting.
PRE_EXISTING=()
for d in "${TODO_DIRS[@]}"; do
    if [ -f "$d/SUCCESS" ] || [ -f "$d/FAILURE" ]; then PRE_EXISTING+=("$d"); fi
done

NAMES=()
for d in "${TODO_DIRS[@]}"; do NAMES+=("$(basename "$d")"); done

KORU_RUN_TODO=1 ./run_regression.sh --no-cache --parallel "${KORU_SWEEP_PARALLEL:-8}" \
    "${NAMES[@]}" >/tmp/todo_sweep_run.log 2>&1
echo "  run log: /tmp/todo_sweep_run.log"
echo

# A test PINS SOMETHING if it names an expected output or an assertion. This
# mirrors the harness's own MUST_ERROR gate condition rather than inventing a
# second predicate.
pins_something() {
    local d="$1"
    [ -s "$d/expected.txt" ] && return 0
    [ -s "$d/expected_error.txt" ] && return 0
    [ -s "$d/expected_patterns.txt" ] && return 0
    [ -s "$d/expected_comptime.txt" ] && return 0
    [ -f "$d/post.sh" ] && return 0
    grep -qE "^(CONTAINS|NOT_CONTAINS|STDOUT_CONTAINS:|ERROR_AT) " "$d/EXPECT" 2>/dev/null && return 0
    return 1
}

PROMOTABLE=(); VACUOUS=(); STILL_RED=(); NO_INPUT=(); NO_VERDICT=()

for d in "${TODO_DIRS[@]}"; do
    name="$(basename "$d")"
    if [ ! -f "$d/input.kz" ] && [ ! -f "$d/input.k" ]; then
        NO_INPUT+=("$name"); continue
    fi
    if [ -f "$d/SUCCESS" ] && [ ! -f "$d/FAILURE" ]; then
        if pins_something "$d"; then PROMOTABLE+=("$name"); else VACUOUS+=("$name"); fi
    elif [ -f "$d/FAILURE" ]; then
        STILL_RED+=("$name|$(head -c 40 "$d/FAILURE" 2>/dev/null | tr -d '\n')")
    else
        NO_VERDICT+=("$name")
    fi
done

echo "${BOLD}═══ todo-sweep results ═══${NC}"
printf '  %s%-11s%s %3d  %s\n' "$GREEN"  "PROMOTABLE" "$NC" "${#PROMOTABLE[@]}" "passes AND pins something — promote it"
printf '  %s%-11s%s %3d  %s\n' "$YELLOW" "VACUOUS"    "$NC" "${#VACUOUS[@]}"    "passes but pins NOTHING — needs an expectation, not a promotion"
printf '  %s%-11s%s %3d  %s\n' "$RED"    "STILL RED"  "$NC" "${#STILL_RED[@]}"  "genuinely not implemented yet"
printf '  %s%-11s%s %3d  %s\n' "$CYAN"   "NO INPUT"   "$NC" "${#NO_INPUT[@]}"   "no input.k/.kz — a backlog note, not a test"
[ "${#NO_VERDICT[@]}" -gt 0 ] && \
printf '  %s%-11s%s %3d  %s\n' "$CYAN"   "NO VERDICT" "$NC" "${#NO_VERDICT[@]}" "ran but wrote no marker — investigate"
echo

if [ "${#PROMOTABLE[@]}" -gt 0 ]; then
    echo "${GREEN}${BOLD}PROMOTABLE — these assert something and now pass:${NC}"
    for n in "${PROMOTABLE[@]}"; do
        d=$(printf '%s\n' "${TODO_DIRS[@]}" | grep -m1 "/$n\$")
        if is_declared "$d"; then
            echo "  ✅ $n"
            echo "     ${BOLD}RESIDUAL DISCHARGED${NC} — the witness came true. Delete its"
            echo "     declaration from todo/todo.kz AND the comment at the site it names."
        else
            echo "  ✅ $n  (drop the TODO marker)"
        fi
    done
    echo
fi

if [ "${#VACUOUS[@]}" -gt 0 ]; then
    echo "${YELLOW}${BOLD}VACUOUS PASS — green because nothing is asserted. Do NOT promote:${NC}"
    for n in "${VACUOUS[@]}"; do
        d=$(printf '%s\n' "${TODO_DIRS[@]}" | grep -m1 "/$n\$")
        why="pins no expected output"
        [ -f "$d/MUST_RUN" ] && why="MUST_RUN with no expected.txt — passes on ANY output"
        echo "  ⚠️  $n  ($why)"
    done
    echo
fi

if [ "${#NO_INPUT[@]}" -gt 0 ]; then
    echo "${CYAN}Backlog notes with no test program:${NC}"
    for n in "${NO_INPUT[@]}"; do echo "  📄 $n"; done
    echo
fi

if [ "${#STILL_RED[@]}" -gt 0 ]; then
    echo "${CYAN}Still unimplemented (reason as the harness saw it):${NC}"
    for e in "${STILL_RED[@]}"; do printf '  · %-52s %s\n' "${e%%|*}" "${e##*|}"; done
    echo
fi

if [ "$KEEP_MARKERS" = false ]; then
    for d in "${TODO_DIRS[@]}"; do
        keep=false
        for p in ${PRE_EXISTING+"${PRE_EXISTING[@]}"}; do [ "$p" = "$d" ] && keep=true && break; done
        [ "$keep" = false ] && rm -f "$d/SUCCESS" "$d/FAILURE"
    done
    echo "  (verdict markers cleaned; --keep-markers to inspect them)"
fi

[ "${#PROMOTABLE[@]}" -gt 0 ] && exit 1
exit 0
