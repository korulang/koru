#!/bin/bash
# Verify: ~[pure] annotation lifts proc to is_pure=true, is_transitively_pure=true.
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

p = find('proc_decl', 'compute')
check(p, 'compute proc', 'is_pure', True)
print("✓ compute proc: is_pure = true (annotation lifted default)")
check(p, 'compute proc', 'is_transitively_pure', True)
print("✓ compute proc: is_transitively_pure = true (no calls, so trivially transitive)")
print()
print("✓ ~[pure] annotation correctly propagates to is_pure=true and is_transitively_pure=true")
EOF
exit $?
