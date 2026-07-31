#!/bin/bash
# Verify: a [pure] proc inside an imported module is transitively pure in the
# serialized AST — Phase 3 recurses into module_decl items, so module procs
# reach the same fixed point as top-level ones. Asserted against
# program.ast.json, the artifact the backend loads (same mechanism as the
# 410 siblings).

if [ ! -f "program.ast.json" ]; then
    echo "✗ program.ast.json not found"
    exit 1
fi

python3 - <<'EOF'
import json, sys
d = json.load(open('program.ast.json'))

def walk_items(items):
    for it in items:
        yield it
        if 'module_decl' in it:
            yield from walk_items(it['module_decl'].get('items') or [])

def find_proc(segs_wanted):
    for it in walk_items(d['items']):
        if 'proc_decl' in it:
            v = it['proc_decl']
            segs = (v.get('path') or {}).get('segments') or []
            if segs == segs_wanted:
                return v
    return None

p = find_proc(['assert', 'fail'])
if p is None:
    print("✗ Could not find module proc assert.fail in serialized AST")
    sys.exit(1)
if p.get('is_pure') is not True:
    print(f"✗ FAIL: assert.fail should have is_pure = true, got {p.get('is_pure')}")
    sys.exit(1)
print("✓ assert.fail (module proc): is_pure = true")
if p.get('is_transitively_pure') is not True:
    print(f"✗ FAIL: assert.fail should have is_transitively_pure = true, got {p.get('is_transitively_pure')}")
    sys.exit(1)
print("✓ assert.fail (module proc): is_transitively_pure = true")

# In-file control: the top-level pure chain still propagates (410_014 shape)
def find_top(kind, name):
    for it in d['items']:
        if kind in it:
            v = it[kind]
            segs = (v.get('path') or {}).get('segments') or []
            if segs and segs[-1] == name:
                return v
    return None

c = find_top('proc_decl', 'compute')
if c is None:
    print("✗ Could not find top-level compute proc")
    sys.exit(1)
if c.get('is_transitively_pure') is not True:
    print(f"✗ FAIL: compute should have is_transitively_pure = true, got {c.get('is_transitively_pure')}")
    sys.exit(1)
print("✓ compute (top-level proc): is_transitively_pure = true")
print()
print("✓ Module-level [pure] proc reaches the transitive fixed point")
EOF
exit $?
