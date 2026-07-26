#!/usr/bin/env bash
# prose_check.sh — the no-prose / pipeline-coherence watcher (enforcement E).
#
# Prose drifts and contaminates; the tests are the only source of truth. The
# by-example pipeline once manufactured drifting prose at scale (a stale claim in
# 5 places). This watcher makes that structurally impossible — three pure-FACT
# checks, no judge:
#
#   A (blocking) generated artifacts == regeneration  — catches hand-edits to a generated file
#   B (blocking) the config carries no prose fields    — catches re-contamination at the source
#   C (blocking) no duplicate NNN_NNN test ID          — the pointer-as-truth precondition
#                (the 55 historical dupes were drained; a duplicate id now fails the run)
#
# Run from anywhere: bash scripts/prose_check.sh   (CANNOT lie — it regenerates and diffs.)
set -o pipefail
cd "$(dirname "$0")/.."
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
fail=0

echo "prose-check — no-prose / pipeline coherence"

# --- A: generated == regeneration -------------------------------------------
GEN_PATHS=(koru-by-example.md koru-tutorial.md docs/by-example \
           skills/koru/SKILL.md skills/koru-templates/SKILL.md skills/koru-metaprogramming/SKILL.md)
node scripts/generate-skills.js   >/dev/null 2>&1
node scripts/generate-corpus.js   >/dev/null 2>&1
node scripts/generate-tutorial.js >/dev/null 2>&1
if git diff --quiet HEAD -- "${GEN_PATHS[@]}"; then
  echo -e "  ${GREEN}✓ A${NC} generated artifacts == regeneration"
else
  echo -e "  ${RED}✗ A${NC} a generated artifact differs from its regeneration (hand-edited):"
  git diff --stat HEAD -- "${GEN_PATHS[@]}" | sed 's/^/      /'
  echo "      Never hand-edit a generated file — edit koru-by-example.json and regenerate."
  fail=1
fi

# --- B: the config carries no prose fields ----------------------------------
B=$(python3 - <<'PY'
import json
d = json.load(open('koru-by-example.json'))
bad = [t.get('name', '?') for t in d.get('topics', []) if 'intro' in t or 'rules' in t]
if any(k in d.get('tutorial', {}) for k in ('intro', 'rules')):
    bad.append('tutorial')
print(','.join(bad))
PY
)
if [ -z "$B" ]; then
  echo -e "  ${GREEN}✓ B${NC} config carries no prose fields (intro/rules)"
else
  echo -e "  ${RED}✗ B${NC} prose fields re-entered koru-by-example.json: ${B}"
  echo "      The config is routing + test selection only. Prose drifts — remove intro/rules."
  fail=1
fi

# --- C: no duplicate NNN_NNN test ID (blocking) -----------------------------
DUPES=$(find tests/regression -type d -name '[0-9][0-9][0-9]_[0-9][0-9][0-9]_*' -not -path '*/_archive/*' \
        | sed 's#.*/##' | awk -F_ '{print $1"_"$2}' | sort | uniq -d)
n=$(printf '%s' "$DUPES" | grep -c . || true)
if [ "$n" -eq 0 ]; then
  echo -e "  ${GREEN}✓ C${NC} all NNN_NNN test IDs are unique"
else
  echo -e "  ${RED}✗ C${NC} ${n} duplicate NNN_NNN id(s) — pointers to them are ambiguous:"
  printf '%s\n' "$DUPES" | sed 's/^/      /'
  echo "      A duplicate id breaks 'a path cannot drift'. Renumber so every NNN_NNN is globally unique."
  fail=1
fi

# --- D: every koru_std comptime transform is accounted for by the mirror wall -
# A transform's subject living in a module is a position the corpus never tested,
# because in the entry file the file-derived name, the import-derived logical
# name and the emitted `main_module` are the same word. Five libraries shipped
# the same class of fault behind that collapse. The 115 cluster mirrors each
# transform; this check is what keeps it a wall rather than a snapshot of one
# afternoon — a new transform fails the suite until someone decides, in writing,
# whether it has a mirror or why it cannot.
#
# Enforced over koru_std only: koru-libs is a sibling repo and may be absent.
D=$(python3 - <<'PY'
import re, pathlib, sys

root = pathlib.Path('.')
manifest = root / 'tests/regression/100_MODULE_SYSTEM/115_COMPTIME_MIRROR/COVERAGE.md'
if not manifest.exists():
    print(f"MISSING-MANIFEST\t{manifest}")
    sys.exit()

REASONS = {'no-green-usage', 'pins-unimplemented-surface', 'tested-in-koru-libs'}

# A markdown table, not a TSV: tests/regression/.gitignore is an explicit
# allowlist and *.md is on it, so the manifest is readable as a document AND
# tracked without touching the ignore rules.
rows = {}
for line in manifest.read_text().splitlines():
    line = line.strip()
    if not line.startswith('|'):
        continue
    cells = [c.strip().strip('`').strip() for c in line.strip('|').split('|')]
    if len(cells) != 2:
        continue
    key, val = cells
    # A transform key is always `lib:name`. That one test skips the header row,
    # its `---` separator, and the reason-legend table above — whose own rows are
    # otherwise indistinguishable from data.
    if ':' not in key:
        continue
    if val in REASONS or val.startswith(('115_', '690_')):
        rows[key] = val
    else:
        print(f"MALFORMED-ROW\t{key}\t{val}")

# The declaration form is `~[...comptime|transform...]pub tor NAME {`, with an
# optional space before `pub`. Commented-out declarations do not count.
decl = re.compile(r'^~\[[^\]]*\bcomptime\|transform\b[^\]]*\]\s*pub\s+tor\s+([A-Za-z0-9_.-]+)')
declared = set()
for f in sorted((root / 'koru_std').glob('*.kz')):
    lib = f.stem
    for line in f.read_text(errors='replace').splitlines():
        m = decl.match(line.strip())
        if m:
            declared.add(f"{lib}:{m.group(1)}")

for t in sorted(declared - rows.keys()):
    print(f"UNDECLARED\t{t}")

# A row naming a koru_std lib that no longer declares it is a stale row. Rows for
# other libs (vaxis, sqlite3) are out of scope and skipped.
std_libs = {f.stem for f in (root / 'koru_std').glob('*.kz')}
for t in sorted(rows.keys() - declared):
    if t.split(':', 1)[0] in std_libs:
        print(f"STALE\t{t}")

# A mirror must name a test directory that exists, anywhere in the corpus — the
# store pair points at 690_079, outside the cluster.
dirs = {p.name for p in root.glob('tests/regression/**/') if p.is_dir()}
for t, d in sorted(rows.items()):
    if d in REASONS:
        continue
    if d not in dirs:
        print(f"NO-SUCH-TEST\t{t}\t{d}")
PY
)
if [ -z "$D" ]; then
  nD=$(grep -cE '^\| `[a-z0-9_]+:' tests/regression/100_MODULE_SYSTEM/115_COMPTIME_MIRROR/COVERAGE.md)
  echo -e "  ${GREEN}✓ D${NC} all koru_std comptime transforms accounted for by the mirror wall (${nD} rows)"
else
  echo -e "  ${RED}✗ D${NC} the comptime mirror wall is out of date:"
  printf '%s\n' "$D" | sed 's/^/      /'
  echo "      UNDECLARED   — a new transform with no row. Add a 115_* mirror, or a reason."
  echo "      STALE        — a row for a transform koru_std no longer declares. Remove it."
  echo "      NO-SUCH-TEST — a row naming a test directory that does not exist."
  echo "      Manifest: tests/regression/100_MODULE_SYSTEM/115_COMPTIME_MIRROR/COVERAGE.md"
  fail=1
fi

echo ""
if [ "$fail" -ne 0 ]; then
  echo -e "${RED}prose-check FAILED${NC}"
  exit 1
fi
echo -e "${GREEN}prose-check OK${NC} (A/B/C/D all green — generated==regen, no prose fields, unique test ids, mirror wall current)"
