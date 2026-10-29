#!/usr/bin/env bash
# claims-ast oracle gate — the K3 half of the "evidence follows AST"
# channel leg. verify/claims_ast/claims_ast_check.py re-runs the claims
# pass's own extraction over program.ast.json — claim-site harvest,
# subject resolution, `&`-type rows, guard DNF arm meets, fold-head
# entry bindings, back-edge substitutions, the FM discharge itself —
# and requires the committed [claim-check]/[claim-term]/[claim-goal]/
# [claim-head]/[claim-edge]/[claim-census] ledger to equal the artifact's
# own derivation, line for line. The pass's pre-image is never trusted.
#
# The boundary is named: program.ast.json precedes `run-pre-transforms`
# inside `elaborate`, while pass-claims-check reads `mutable_ctx.ast`
# after it — a transform that rewrites a claim's subject region makes the
# committed rows underivable, and the oracle fails loud rather than
# paper over the seam.
#
# Usage:
#   claims_ast_gate.sh <program.ast.json> <backend.err>
#   claims_ast_gate.sh --selfcheck
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
CK="$DIR/verify/claims_ast/claims_ast_check.py"

if [ "${1:-}" = "--selfcheck" ]; then
    echo "-- claims-ast selfcheck (fixtures)"
    rc=0
    for f in "$DIR"/verify/claims_ast/fixtures/*/; do
        name="$(basename "$f")"
        if python3 "$CK" --selfcheck "$f"; then :; else rc=1; fi
    done
    if [ "$rc" -eq 0 ]; then
        echo "claims-ast gate: SELFCHECK PASS"
    else
        echo "claims-ast gate: SELFCHECK FAIL" >&2
    fi
    exit "$rc"
fi

[ $# -ge 2 ] || { echo "usage: claims_ast_gate.sh <program.ast.json> <backend.err>" >&2; exit 2; }
[ -f "$1" ] || { echo "claims-ast gate: no program.ast.json at $1" >&2; exit 1; }
[ -f "$2" ] || { echo "claims-ast gate: no backend.err at $2" >&2; exit 1; }

python3 "$CK" "$1" "$2"
