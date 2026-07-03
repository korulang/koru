#!/bin/bash
# Verify: module annotations serialize — std.io [comptime|runtime], std.compiler [comptime].
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

mods = {it['module_decl']['logical_name']: it['module_decl'].get('annotations') or []
        for it in d['items'] if 'module_decl' in it}
if mods.get('std.io') != ['comptime', 'runtime']:
    print(f"FAIL: std.io should have annotations ['comptime', 'runtime'], got {mods.get('std.io')}")
    sys.exit(1)
if mods.get('std.compiler') != ['comptime']:
    print(f"FAIL: std.compiler should have annotations ['comptime'], got {mods.get('std.compiler')}")
    sys.exit(1)
print("PASS: All module annotations correctly serialized")
EOF
exit $?
