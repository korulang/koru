#!/usr/bin/env bash
# kz_convertible.sh — the .kz -> .k migration-backlog lint.
#
# Reports every currently-GREEN `.kz` test that is ALSO green as `.k` — i.e.
# a pure-Koru program still wearing the host-facet extension. The backlog is a
# number that should trend to zero: it catches a newly-authored `.kz` the day
# it lands, so `.k`-preference stops depending on anyone remembering to sweep.
#
# TWO TIERS, because honesty has a cost:
#
#   (default) FAST PREVIEW — marker + grep pre-filter, instant, READ-ONLY, safe
#     to run anytime even with other sessions active. It OVER-REPORTS: the grep
#     can't see host content hiding in shared syntax (a bare untyped
#     `const x = true;` is a host line in .kz; `struct {}`, typed consts, etc.).
#     So it prints CANDIDATES, never "convertible". This is a preview, not a verdict.
#
#   --verify  AUTHORITATIVE — the compile-gate oracle. Rename+strip each candidate,
#     compile & RUN it as `.k`, keep only green-both-ways. This is the ONLY honest
#     convertibility test (a grep predicate was tried as --check-k-convertible and
#     ruled out — it over-reports, and can't see shared-syntax host content).
#     Runs in a THROWAWAY git worktree off HEAD so it never mutates your checkout —
#     critical while concurrent sessions may `git add -A` on the same branch.
#
# Exit status: 0 always (a report, not a gate). Use the printed count.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"
REG="tests/regression"

VERIFY=false
[ "${1:-}" = "--verify" ] && VERIFY=true

# --- shared classification (mirrors migrate_kz_to_k.sh; the compiler is the oracle) ---
is_green()        { [ -f "$1/SUCCESS" ] && [ ! -f "$1/FAILURE" ]; }
is_error_expect() { [ -f "$1/EXPECT" ] && grep -qE 'FRONTEND_COMPILE_ERROR|BACKEND_COMPILE_ERROR|BACKEND_RUNTIME_ERROR|BACKEND_EXEC_ERROR|MUST_ERROR' "$1/EXPECT"; }
# Exclusions that are NOT migration targets regardless of content:
#   MUST_ERROR / error-EXPECT  — negatives; a rename can change which error fires.
#   LANGUAGES                 — multi-target facet.
#   input.k present           — collision.
#   expected.json             — AST-snapshot tests: the .kz AST embeds the literal
#                               input.kz filename + parses comments as host_line
#                               nodes, so .k legitimately differs. They stay .kz.
skip_dir()    { [ -f "$1/MUST_ERROR" ] || [ -f "$1/LANGUAGES" ] || [ -f "$1/input.k" ] \
                || [ -f "$1/expected.json" ] || is_error_expect "$1"; }
# Cheap host-content pre-filter. Deliberately conservative — anything it flags is
# excluded from the FAST preview, but the --verify gate is what actually decides.
host_markers() { grep -lE -- '\|zig|@import|pub fn|\bfn |\bvar |(~?struct)\b' "$1" 2>/dev/null; }

# Collect green .kz candidates that survive the pre-filter. Prints test dirs.
candidates() {
  while IFS= read -r kz; do
    dir=$(dirname "$kz")
    skip_dir "$dir" && continue
    is_green "$dir" || continue
    [ -z "$(host_markers "$kz")" ] && echo "$dir"
  done < <(find "$REG" -name input.kz | sort)
}

# ---------------------------------------------------------------------------
if [ ! -e "$(find "$REG" -name SUCCESS -print -quit 2>/dev/null)" ] 2>/dev/null; then :; fi
mapfile -t CAND < <(candidates)
N=${#CAND[@]}

if ! $VERIFY; then
  echo "════════════════════════════════════════════════════════════════"
  echo " .kz -> .k MIGRATION BACKLOG  (fast preview — grep pre-filter)"
  echo "════════════════════════════════════════════════════════════════"
  echo " $N green .kz CANDIDATES look structurally pure."
  echo " ⚠  Preview OVER-REPORTS: the grep can't see host content in shared"
  echo "    syntax (bare untyped const, struct, typed const). It is NOT a verdict."
  echo "    Run  ./run_regression.sh --kz-convertible --verify  to compile-gate."
  echo "────────────────────────────────────────────────────────────────"
  for d in "${CAND[@]}"; do echo "  ${d#"$REG"/}"; done
  [ "$N" -eq 0 ] && echo "  (none — backlog empty by the pre-filter)"
  exit 0
fi

# --- authoritative compile-gate in an isolated worktree ------------------------
if [ "$N" -eq 0 ]; then
  echo "No candidates survive the pre-filter — nothing to compile-gate. Backlog: 0."
  exit 0
fi

WT="$SCRIPT_DIR/.claude/worktrees/kz-convertible-lint"
HEAD_SHA=$(git rev-parse HEAD)
echo "Compile-gating $N candidates in an isolated worktree off $HEAD_SHA …"
echo "(read-only on your checkout; safe under concurrent sessions)"

cleanup() { git worktree remove --force "$WT" >/dev/null 2>&1 || true; }
trap cleanup EXIT
git worktree remove --force "$WT" >/dev/null 2>&1 || true
git worktree add --detach "$WT" "$HEAD_SHA" >/dev/null 2>&1

# Convert every candidate in the worktree (rename + strip one line-start ~).
IDS=()
for d in "${CAND[@]}"; do
  wdir="$WT/$d"
  [ -d "$wdir" ] || continue
  [ -f "$wdir/input.kz" ] || continue
  mv "$wdir/input.kz" "$wdir/input.k"
  sed -i '' -E 's/^([[:space:]]*)~/\1/' "$wdir/input.k" 2>/dev/null || sed -i -E 's/^([[:space:]]*)~/\1/' "$wdir/input.k"
  # Filter by the FULL directory name, not the leading NNN_NNN. Five candidates
  # under 330_PHANTOM_TYPES and 360_TAPS_OBSERVERS are named `520_multiple_…`,
  # `509_tap_observer_…` — one number, not two — so the id regex matched nothing,
  # they were never added here, and the gate reported them as "never ran". The
  # three-state check below caught it rather than miscounting them as "stays
  # .kz", which is the only reason the backlog was not quietly understated.
  IDS+=("$(basename "$d")")
done

# Run ONLY the candidate tests (the first invocation builds koruc; the rest reuse
# it). Far lighter than a full 1079-test suite and gentler on a loaded machine.
for id in "${IDS[@]}"; do
  ( cd "$WT" && ./run_regression.sh --parallel 8 "$id" >/dev/null 2>&1 ) || true
done

# Three-state gate — a candidate with NEITHER marker never actually ran, and
# must NOT be silently miscounted as "stays .kz" (that would fake a 0 backlog).
CONVERTIBLE=(); STAYS=(); DIDNT_RUN=()
for d in "${CAND[@]}"; do
  if   is_green "$WT/$d";              then CONVERTIBLE+=("$d")
  elif [ -f "$WT/$d/FAILURE" ];        then STAYS+=("$d")
  else                                      DIDNT_RUN+=("$d")
  fi
done

echo "════════════════════════════════════════════════════════════════"
echo " .kz -> .k MIGRATION BACKLOG  (VERIFIED — compile-gated)"
echo "════════════════════════════════════════════════════════════════"
echo " ${#CONVERTIBLE[@]} of $N candidates are green BOTH ways -> convert these:"
for d in "${CONVERTIBLE[@]}"; do echo "  ✅ ${d#"$REG"/}"; done
[ "${#CONVERTIBLE[@]}" -eq 0 ] && echo "  (none — backlog empty)"
echo "────────────────────────────────────────────────────────────────"
echo " ${#STAYS[@]} survivors compiled RED as .k -> host content the grep"
echo " missed (bare const / struct / typed const); correctly stay .kz."
if [ "${#DIDNT_RUN[@]}" -gt 0 ]; then
  echo "────────────────────────────────────────────────────────────────"
  echo " ⛔ ${#DIDNT_RUN[@]} candidates produced NO marker — they never ran."
  echo "    The verdict above is INCOMPLETE; investigate the harness, do not"
  echo "    trust the count:"
  for d in "${DIDNT_RUN[@]}"; do echo "    ? ${d#"$REG"/}"; done
  exit 3
fi
exit 0
