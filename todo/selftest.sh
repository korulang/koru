#!/usr/bin/env bash
# Self-test for the residual gate — prove it still refuses before trusting it.
#
# The gate in koru_std/todo.kz decides one question: can this residual be
# driven? A gate that has only ever been watched AGREE is not a gate, and this
# repo has already paid for that lesson — three real bugs in the emitted-while
# checker surfaced only when it was fed things it was obliged to reject.
#
# So: todo/selftest.kz declares three deliberately broken residuals, one per
# failure mode, and this script asserts the gate catches all three AND that the
# real manifest beside it still passes. If the refusals stop firing, the
# manifest's green means nothing, and this reports BROKEN rather than clean.
#
# Usage:  todo/selftest.sh
# Exit:   0 all refusals fire and the manifest passes; 1 otherwise.

set -uo pipefail
cd "$(dirname "$0")" || exit 1

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; BOLD=$'\033[1m'; NC=$'\033[0m'
KORUC=../zig-out/bin/koruc

if [ ! -x "$KORUC" ]; then
    echo "${RED}BROKEN: no compiler at $KORUC — run zig build first.${NC}"
    exit 1
fi

FAILED=0

check_contains() {
    local haystack="$1" needle="$2" label="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  ${GREEN}✓${NC} $label"
    else
        echo "  ${RED}✗ $label — expected to see: $needle${NC}"
        FAILED=1
    fi
}

echo "${BOLD}residual-gate self-test${NC}"
echo

# ── The three refusals ────────────────────────────────────────────────────────
SABOTAGE=$("$KORUC" selftest.kz todo 2>&1)
SABOTAGE_RC=$?

if [ "$SABOTAGE_RC" -eq 0 ]; then
    echo "  ${RED}✗ the gate ACCEPTED three broken declarations (exit 0)${NC}"
    echo "    Nothing below this line can be trusted. The gate has stopped checking."
    FAILED=1
else
    echo "  ${GREEN}✓${NC} broken manifest refused (exit $SABOTAGE_RC)"
fi

check_contains "$SABOTAGE" "MISSING"   "a residual with no witness is named as undrivable"
check_contains "$SABOTAGE" "NOT FOUND" "a witness absent from the corpus is caught"
check_contains "$SABOTAGE" "VACUOUS"   "a witness that asserts nothing is caught"

echo

# ── The real manifest still passes ────────────────────────────────────────────
# Both directions matter. A gate that refuses everything is as useless as one
# that refuses nothing, and a manifest that has quietly gone red would otherwise
# be indistinguishable from the sabotage above.
"$KORUC" todo.kz todo >/dev/null 2>&1
MANIFEST_RC=$?
if [ "$MANIFEST_RC" -eq 0 ]; then
    echo "  ${GREEN}✓${NC} the real manifest passes (exit 0)"
else
    echo "  ${RED}✗ todo/todo.kz is RED (exit $MANIFEST_RC) — a declared residual lost its witness${NC}"
    FAILED=1
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "${GREEN}${BOLD}residual gate is live: refuses what it must, passes what it must.${NC}"
    exit 0
fi
echo "${RED}${BOLD}residual gate BROKEN — do not trust todo/todo.kz until this is green.${NC}"
exit 1
