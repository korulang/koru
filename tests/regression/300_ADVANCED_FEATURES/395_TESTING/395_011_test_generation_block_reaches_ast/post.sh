#!/bin/bash
# The generated test block must reach output_emitted.zig. Decided with the
# variant-coverage checker's own bare-token predicate, not a plain grep: the
# whole point is bare code versus a string literal, which grep cannot tell
# apart.

cd "$(dirname "$0")"
ROOT="$(cd ../../../../.. && pwd)"

python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "invariants" / "checks"))
from check_variant_coverage import bare_tokens, marker_pattern

artifact = Path("output_emitted.zig")
if not artifact.exists():
    print("FAIL: no output_emitted.zig — the backend never emitted the program")
    sys.exit(1)

pattern = marker_pattern("__mock_result_{}")
hits = sorted(t for t in bare_tokens(artifact) if pattern.match(t))
if hits:
    print("PASS: emitted program carries the mock substitution:", ", ".join(hits))
    sys.exit(0)

print("FAIL: no bare __mock_result_N token in output_emitted.zig.")
print("  processTestFlow generated the test block (it panics from inside itself")
print("  on a bad mock, and on an unmocked impure event), but the block never")
print("  reached the AST — see BUG.md.")
sys.exit(1)
PY
