#!/usr/bin/env bash
# strip-ast oracle gate — the shared channel rung for the "evidence follows
# AST" boundary both K2 (dead-strip) and K3 (claims) name.
#
# verify/strip_ast/strip_ast_check.py re-derives dead-strip's reachability
# pre-image from program.ast.json — the serialized frontend->backend channel
# the backend deserializes as `original_ast` — and re-decides the committed
# [witness] site strip-* ledger against it. A ledger that under-commits the
# spelled set (to license a removal), removes a spelled path, invents a
# root, or mis-reports cargo is caught here — the pass's own `used` set is
# never trusted.
#
# Usage:
#   strip_ast_gate.sh <program.ast.json> <backend.err> [--library]
#   strip_ast_gate.sh --selfcheck
#
# --selfcheck re-decides the bundled fixtures: honest must conform, tampered
# must fail (the fixture commits an unlawful removal of a spelled path).
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
CK="$DIR/verify/strip_ast/strip_ast_check.py"

if [ "${1:-}" = "--selfcheck" ]; then
    echo "-- strip-ast selfcheck (fixtures)"
    if python3 "$CK" "$DIR/verify/strip_ast/fixtures/honest/program.ast.json" \
                      "$DIR/verify/strip_ast/fixtures/honest/backend.err"; then
        echo "selfcheck: honest fixture conforms"
    else
        echo "selfcheck: honest fixture FAILED" >&2
        exit 1
    fi
    if python3 "$CK" "$DIR/verify/strip_ast/fixtures/tampered/program.ast.json" \
                      "$DIR/verify/strip_ast/fixtures/tampered/backend.err" 2>/dev/null; then
        echo "selfcheck: tampered fixture CONFORMED — oracle is blind" >&2
        exit 1
    else
        echo "selfcheck: tampered fixture rejected"
    fi
    echo "strip-ast gate: SELFCHECK PASS"
    exit 0
fi

[ $# -ge 2 ] || { echo "usage: strip_ast_gate.sh <program.ast.json> <backend.err> [--library]" >&2; exit 2; }
[ -f "$1" ] || { echo "strip-ast gate: no program.ast.json at $1" >&2; exit 1; }
[ -f "$2" ] || { echo "strip-ast gate: no backend.err at $2" >&2; exit 1; }

python3 "$CK" "$1" "$2" ${3:-}
