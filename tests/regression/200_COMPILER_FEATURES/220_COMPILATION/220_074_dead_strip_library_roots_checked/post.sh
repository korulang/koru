#!/bin/bash
# Rung B — the strip-root law needs a `koruc lib` compile to be exercised at
# all: program compiles commit zero roots, so the root machinery only saw
# synthetic corpora before this test. The lib-mode stderr lands in
# lib_backend.err beside the primary backend.err so both ledgers stay
# inspectable; the gate re-decides it under --library, where every pub
# entry-module event_decl must be a committed root and every committed
# root must be a pub decl.
set -u

koruc lib "$KORU_INPUT" >lib.out 2>lib_backend.err || {
    echo "FAIL: koruc lib refused the input"
    exit 1
}
grep -q 'strip-root' lib_backend.err || {
    echo "FAIL: lib compile committed no strip-root lines — nothing pinned"
    exit 1
}
REPO="$(cd "$(dirname "$0")/../../../../.." && pwd)"
"$REPO/scripts/strip_ast_gate.sh" program.ast.json lib_backend.err --library || {
    echo "FAIL: strip-ast oracle rejected the lib ledger"
    exit 1
}
echo "PASS: lib roots re-decided against artifact"
exit 0
