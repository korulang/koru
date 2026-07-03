#!/bin/bash
# Verify: an unannotated proc is structurally impure (Layer 1 fact).
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

p = find('proc_decl', 'log')
check(p, 'log proc', 'is_pure', False)
print("✓ log proc: is_pure = false (unannotated → structural default)")
check(p, 'log proc', 'is_transitively_pure', False)
print("✓ log proc: is_transitively_pure = false")
print()
print("✓ Unannotated proc correctly defaults to structurally impure")
EOF
exit $?
