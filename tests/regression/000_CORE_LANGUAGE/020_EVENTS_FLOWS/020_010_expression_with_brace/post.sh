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

# Expression argument with braces parsed correctly: name="val", value="{ foo: 1 }".
d = json.load(open("program.ast.json"))

def args(o):
    if isinstance(o, dict):
        if "args" in o and isinstance(o["args"], list):
            for a in o["args"]:
                if isinstance(a, dict):
                    yield a
        for v in o.values():
            yield from args(v)
    elif isinstance(o, list):
        for v in o:
            yield from args(v)

hit = any(a.get("name") == "val" and a.get("value") == "{ foo: 1 }" for a in args(d))
if not hit:
    print("ERROR: Expression argument not parsed correctly")
    print('Expected an arg with name="val", value="{ foo: 1 }"')
    sys.exit(1)
print("✓ Expression argument parsed correctly: name=val, value={ foo: 1 }")
PYEOF
