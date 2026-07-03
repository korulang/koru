#!/bin/bash
# Verify: Expression argument with braces parses to name='val', value='{ foo: 1 }'.
#
# Re-pointed 2026-07-03: the serialized-AST Zig literal (backend.zig /
# program_ast.zig) is RETIRED — the backend loads program.ast.json at
# runtime, so that JSON is the serialized AST and the artifact to assert
# against. The old grep-the-Zig-literal form passed on stale artifacts
# only (the harness never cleaned program_ast.zig).

if [ ! -f "program.ast.json" ]; then
    echo "✗ program.ast.json not found"
    exit 1
fi

python3 - <<'EOF'
import json, sys
d = json.load(open('program.ast.json'))

def find(kind, name):
    for it in d['items']:
        if kind in it:
            v = it[kind]
            segs = (v.get('path') or {}).get('segments') or []
            if segs and segs[-1] == name:
                return v
    return None

def first_flow():
    for it in d['items']:
        if 'flow' in it:
            return it['flow']
    return None

def check(entity, label, field, want):
    if entity is None:
        print(f"✗ Could not find {label}")
        sys.exit(1)
    got = entity.get(field)
    if got is not want:
        print(f"✗ FAIL: {label} should have {field} = {str(want).lower()}, got {str(got).lower()}")
        sys.exit(1)

def all_args(o):
    if isinstance(o, dict):
        if 'args' in o and isinstance(o['args'], list):
            for a in o['args']:
                if isinstance(a, dict): yield a
        for v in o.values(): yield from all_args(v)
    elif isinstance(o, list):
        for v in o: yield from all_args(v)
for a in all_args(d):
    if a.get('name') == 'val' and a.get('value') == '{ foo: 1 }':
        print("✓ Expression argument parsed correctly: name='val', value='{ foo: 1 }'")
        break
else:
    print("ERROR: Expression argument not parsed correctly")
    print("Expected an arg with name='val', value='{ foo: 1 }' in program.ast.json")
    sys.exit(1)
EOF
exit $?
