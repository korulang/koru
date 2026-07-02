#!/bin/bash
# The AST is a runtime artifact now: program.ast.json (dynamic-AST, ff5ccb08).
# The old Zig-source literal (program_ast.zig) is no longer emitted — checking
# it validated a stale fossil from whatever run last produced one (found
# 2026-07-02: main was green against a four-day-old file). This script reads
# the JSON the compiler actually wrote THIS run.

if [ ! -f "program.ast.json" ]; then
    echo "✗ program.ast.json not found — backend did not run"
    exit 1
fi

python3 - <<'PYEOF'

import json, sys

def load():
    return json.load(open("program.ast.json"))

def walk(o, kind):
    """Yield every node of the given decl kind (event_decl / proc_decl / flow)."""
    if isinstance(o, dict):
        if kind in o and isinstance(o[kind], dict):
            yield o[kind]
        for v in o.values():
            yield from walk(v, kind)
    elif isinstance(o, list):
        for v in o:
            yield from walk(v, kind)

def find_decl(d, kind, module, name):
    for n in walk(d, kind):
        p = n.get("path", {})
        if p.get("module_qualifier") == module and p.get("segments") == [name]:
            return n
    return None

def check(node, what, expect_pure, expect_trans):
    if node is None:
        print(f"✗ Could not find {what} in program.ast.json"); sys.exit(1)
    if node.get("is_pure") is not expect_pure:
        print(f"✗ FAIL: {what} should be is_pure = {str(expect_pure).lower()}"); sys.exit(1)
    print(f"✓ {what}: is_pure = {str(expect_pure).lower()}")
    if node.get("is_transitively_pure") is not expect_trans:
        print(f"✗ FAIL: {what} should be is_transitively_pure = {str(expect_trans).lower()}"); sys.exit(1)
    print(f"✓ {what}: is_transitively_pure = {str(expect_trans).lower()}")


# Program with [pure] on an event compiled cleanly — annotations are open
# metadata at the frontend; misplaced annotations are not rejected.
d = load()
if find_decl(d, "event_decl", "input", "noop") is None:
    print("✗ FAIL: noop event not found in program.ast.json"); import sys; sys.exit(1)
print("✓ program with [pure] on event compiled cleanly (annotations are open metadata)")
PYEOF
