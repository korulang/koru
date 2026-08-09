#!/usr/bin/env bash
# prose_check.sh — the no-prose / pipeline-coherence watcher (enforcement E).
#
# Prose drifts and contaminates; the tests are the only source of truth. The
# by-example pipeline once manufactured drifting prose at scale (a stale claim in
# 5 places). This watcher makes that structurally impossible — five pure-FACT
# checks, no judge:
#
#   A (blocking) generated artifacts == regeneration  — catches hand-edits to a generated file
#   B (blocking) the config carries no prose fields    — catches re-contamination at the source
#   C (blocking) no duplicate NNN_NNN test ID          — the pointer-as-truth precondition
#                (the 55 historical dupes were drained; a duplicate id now fails the run)
#   D (blocking) every koru_std comptime transform has a mirror row
#   E (blocking) every NEEDS_RULING marker still sits on a running, still-red test
#
# Run from anywhere: bash scripts/prose_check.sh   (CANNOT lie — it regenerates and diffs.)
set -o pipefail
cd "$(dirname "$0")/.."
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
fail=0

echo "prose-check — no-prose / pipeline coherence"

# --- A: generated == regeneration -------------------------------------------
# The generators read which tests pass from live SUCCESS markers, so the corpus
# they produce is only well defined against a settled marker set. Inside our own
# suite it is settled — prose-check runs last. A FOREIGN suite mid-run is a
# different story: `--no-cache` clears markers before rewriting them, so
# regenerating then yields "0 passing positive tests".
#
# Two defects came out of that, and both are fixed here rather than tolerated.
# Regeneration used to write over the tracked files, making checking and
# mutating one act — so the emptied corpus was left in the working tree for the
# next `git add -A` to publish. And the emptied result was reported as an honest
# "differs", which is a true sentence about nothing.
GEN_PATHS=(koru-by-example.md koru-tutorial.md docs/by-example \
           skills/koru/SKILL.md skills/koru-templates/SKILL.md skills/koru-metaprogramming/SKILL.md)

# A lock held by anyone but our own suite means the corpus is moving underneath
# us. run_regression.sh exports KORU_SUITE_PID so its own lock is recognised.
LOCK="${TMPDIR:-/tmp}/koru-regression.lock"; LOCK="${LOCK%/}"
FOREIGN_SUITE=""
if [ -d "$LOCK" ]; then
  lock_pid=$(cat "$LOCK/pid" 2>/dev/null || echo "")
  # A lock file is evidence, not proof: the holder may be long dead. Both
  # runners already test liveness before honouring a lock; a reader that
  # doesn't will refuse forever on a corpse. Only a LIVE foreign holder means
  # the corpus is actually moving.
  if [ -n "$lock_pid" ] && [ "$lock_pid" != "${KORU_SUITE_PID:-}" ] && kill -0 "$lock_pid" 2>/dev/null; then
    FOREIGN_SUITE="$lock_pid ($(cat "$LOCK/checkout" 2>/dev/null || echo 'unknown checkout'))"
  fi
fi

if [ -n "$FOREIGN_SUITE" ]; then
  # Not clean, not differs — unknowable. Saying either would be inventing a
  # result, and "clean" is the one that would be believed.
  echo -e "  ${RED}✗ A${NC} CANNOT CHECK — another suite is rewriting the test markers this check reads:"
  echo "      pid ${FOREIGN_SUITE}"
  echo "      The corpus is derived from SUCCESS markers, so a regeneration taken now"
  echo "      describes a half-finished run. Re-run when that suite is done."
  fail=1
else
  GEN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/koru-prosecheck.XXXXXX")
  trap 'rm -rf "$GEN_TMP"' EXIT
  # Writes land in GEN_TMP; reads still come from the repo.
  KORU_GEN_OUT_ROOT="$GEN_TMP" node scripts/generate-skills.js   >/dev/null 2>&1
  KORU_GEN_OUT_ROOT="$GEN_TMP" node scripts/generate-corpus.js   >/dev/null 2>&1
  KORU_GEN_OUT_ROOT="$GEN_TMP" node scripts/generate-tutorial.js >/dev/null 2>&1

  A_DIFFS=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ ! -e "$GEN_TMP/$p" ]; then
      A_DIFFS="${A_DIFFS}      ${p} — committed but the generators no longer produce it"$'\n'
      continue
    fi
    if ! git show "HEAD:$p" 2>/dev/null | diff -q - "$GEN_TMP/$p" >/dev/null 2>&1; then
      A_DIFFS="${A_DIFFS}      ${p}"$'\n'
    fi
  done < <(git ls-files -- "${GEN_PATHS[@]}")

  if [ -z "$A_DIFFS" ]; then
    echo -e "  ${GREEN}✓ A${NC} generated artifacts == regeneration (compared out-of-tree)"
  else
    echo -e "  ${RED}✗ A${NC} a generated artifact differs from its regeneration (hand-edited):"
    printf '%s' "$A_DIFFS"
    echo "      Never hand-edit a generated file — edit koru-by-example.json and regenerate."
    echo "      The working tree was NOT modified; regenerate for real to see the diff."
    fail=1
  fi
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

# The declaration form is `~[...comptime|transform...]pub KIND NAME`, with an
# optional space before `pub`. Commented-out declarations do not count.
#
# KIND is tor, event or proc: a wall that only reads `pub tor` sees exactly the
# forms already written, so it can never notice the first transform someone
# spells another way. Same reason the source glob is recursive and covers every
# Koru file form — a transform under `koru_std/optimizations/` or in a `.k`
# would otherwise ship with no row and no complaint.
decl = re.compile(r'^~\[([^\]]*\bcomptime\|transform\b[^\]]*)\]\s*pub\s+(?:tor|event|proc)\s+([A-Za-z0-9_.-]+)')
SRC = sorted(
    p for pat in ('**/*.kz', '**/*.k', '**/*.kjs')
    for p in (root / 'koru_std').glob(pat)
)
declared = set()
keyworded = set()
for f in SRC:
    lib = f.stem
    for line in f.read_text(errors='replace').splitlines():
        m = decl.match(line.strip())
        if m:
            declared.add(f"{lib}:{m.group(2)}")
            if 'keyword' in m.group(1).split('|'):
                keyworded.add(f"{lib}:{m.group(2)}")

for t in sorted(declared - rows.keys()):
    print(f"UNDECLARED\t{t}")

# A row naming a koru_std lib that no longer declares it is a stale row. Rows for
# other libs (vaxis, sqlite3) are out of scope and skipped.
std_libs = {f.stem for f in SRC}
for t in sorted(rows.keys() - declared):
    if t.split(':', 1)[0] in std_libs:
        print(f"STALE\t{t}")

# A mirror must name a test directory that exists, anywhere in the corpus — the
# store pair points at 690_079, outside the cluster.
dirs = {p.name: p for p in root.glob('tests/regression/**/') if p.is_dir()}
for t, d in sorted(rows.items()):
    if d in REASONS:
        continue
    if d not in dirs:
        print(f"NO-SUCH-TEST\t{t}\t{d}")
        continue
    # …and it must USE the transform it claims to mirror. A row survives a test
    # being rewritten to something else, and a row pointing at a test that no
    # longer touches the transform is a mirror on paper only.
    lib, name = t.split(':', 1)
    body = ''
    for src in sorted(dirs[d].glob('*')):
        if src.suffix in ('.k', '.kz', '.kjs'):
            body += src.read_text(errors='replace')
    # A `keyword` transform is invoked bare — `bool(IsActive)`, `capture { … }`
    # — so the qualified spelling is the wrong thing to look for there.
    spellings = [f"std/{lib}:{name}"]
    if t in keyworded:
        spellings += [f"{name}(", f"{name} {{"]
    if not any(s in body for s in spellings):
        print(f"MIRROR-DOES-NOT-USE\t{t}\t{d}")
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

# --- E: every NEEDS_RULING marker still describes its test -------------------------
# A `NEEDS_RULING` file says: this test's verdict is blocked on a decision nobody has
# made. That is prose attached to a red test, and prose attached to a red test is
# checked by nothing (concepts/frag-a-red-pin-is-unfalsifiable-documentation.md).
# One direction of it IS mechanical, and this is that direction: the moment the
# test passes, the claim is false — either the question was answered and the
# marker outlived it, or the pin was measuring something else all along. Both
# want a human, so the run stops.
#
# The lever only exists where markers are LIVE. Two shapes it deliberately does
# not judge, because judging them would be inventing a signal:
#   - a NEEDS_RULING test that is also TODO. TODO short-circuits before koruc runs, so
#     the test has no current verdict at all — and run_regression.sh:937 exempts
#     TODO dirs from marker cleanup, so any SUCCESS sitting there is a fossil of
#     an old `--todo-sweep`, not a live pass. Parked-and-unruled is a legitimate
#     and common state (the spelling is what the ruling decides), so it is
#     allowed and listed by `node scripts/rulings.js` as parked. The sweep is its
#     falsification lever, not this check.
#   - a stub test — TODO/SKIP/BENCHMARK marker and no input file. The harness
#     itself counts those as tests (save-snapshot.js's isValidTest), so this
#     check follows that definition rather than a stricter one of its own.
#
# The first line is the QUESTION and must exist. A marker with nothing written in
# it is a file nothing reads — the class this suite already walls for
# expectations (anchor:cfg-dead-expectation-filename).
E=$(python3 - <<'PY'
import pathlib

root = pathlib.Path('tests/regression')
STUB_MARKERS = ('TODO', 'SKIP', 'BENCHMARK', 'BROKEN')
for marker in sorted(root.rglob('NEEDS_RULING')):
    if '_archive' in marker.parts:
        continue
    d = marker.parent
    rel = d.relative_to(root)
    has_input = (d / 'input.kz').exists() or (d / 'input.k').exists()
    parked = any((d / m).exists() for m in STUB_MARKERS)
    if not has_input and not parked:
        print(f"NEEDS_RULING-ORPHAN\t{rel}")
        continue
    if not marker.read_text(encoding='utf-8', errors='replace').strip():
        print(f"NEEDS_RULING-EMPTY\t{rel}")
    if not parked and (d / 'SUCCESS').exists():
        print(f"NEEDS_RULING-ON-PASSING\t{rel}")
PY
)
if [ -z "$E" ]; then
  nE=$(find tests/regression -name NEEDS_RULING -not -path '*/_archive/*' | wc -l | tr -d ' ')
  echo -e "  ${GREEN}✓ E${NC} every NEEDS_RULING marker still describes its test (${nE} awaiting a ruling)"
else
  echo -e "  ${RED}✗ E${NC} a NEEDS_RULING marker no longer describes its test:"
  printf '%s\n' "$E" | sed 's/^/      /'
  echo "      NEEDS_RULING-ON-PASSING — the test runs and PASSES. The question was settled, or"
  echo "                          the pin rotted. Delete NEEDS_RULING and write the answer into"
  echo "                          the test header (and a concept, if a belief moved)."
  echo "      NEEDS_RULING-EMPTY      — no question written. State it or delete the file."
  echo "      NEEDS_RULING-ORPHAN     — no input file and no TODO/SKIP/BENCHMARK/BROKEN, so"
  echo "                          this directory is not a test at all."
  echo "      The queue: node scripts/rulings.js"
  fail=1
fi

# --- F: no `.k` carries a tilde (blocking) ----------------------------------
# `~` is the switch that tells a HOST-language file where Koru starts. A `.k`
# has no host language, so there is nothing to switch away from and the
# character is refused — which is what 210_203_reject_tilde_in_dot_k pins, one
# file at a time. This is the same rule asked of the whole corpus.
#
# It exists because of a real push: twenty `.kz` tests were renamed with
# `git mv` (which STAGES) and de-tilded with `sed -i` (which does not), so the
# commit carried twenty `.k` files still full of tildes while every test run
# reported green — the runs read the working tree, the push shipped the index.
# See concepts/frag-a-green-run-is-evidence-about-the-tree-not-the-commit.md.
# Reading HEAD rather than the working tree is the whole point of this check.
#
# BLIND SPOTS, stated rather than discovered later: it matches a tilde only at
# the START of a line, and only under tests/regression/**/input.k and
# koru_std/**/*.k. A `~` mid-line — inside a string, inside a comment — is not
# looked at, deliberately, because those are the false positives. A `.k` living
# anywhere else in the repo is not looked at either.
#
# Calibrated by sabotage 2026-08-09, three ways: it names 210_203 when the
# exception is lifted (the pattern really matches); it names a freshly committed
# tilde in a file it had never seen (a scratch worktree, 010_000); and it stays
# GREEN when the same tilde is only in the working tree, which is the property
# that makes it worth having.
TILDE_K=$(git grep -l '^[[:space:]]*~' HEAD -- 'tests/regression/**/input.k' 'koru_std/**/*.k' 2>/dev/null \
          | sed 's#^HEAD:##' | grep -v '210_203_reject_tilde_in_dot_k' || true)
n=$(printf '%s' "$TILDE_K" | grep -c . || true)
if [ "$n" -eq 0 ]; then
  echo -e "  ${GREEN}✓ F${NC} no committed \`.k\` carries a tilde (210_203 excepted — refusing one is what it pins)"
else
  echo -e "  ${RED}✗ F${NC} ${n} committed \`.k\` file(s) carry a tilde:"
  printf '%s\n' "$TILDE_K" | sed 's/^/      /'
  echo "      A \`.k\` is pure Koru: no host language, so no parser switch to write."
  echo "      If the file genuinely has host content it is a \`.kz\`; if not, strip the \`~\`."
  echo "      Checked against HEAD, not the working tree — a green test run proves"
  echo "      nothing about what was staged."
  fail=1
fi

echo ""
if [ "$fail" -ne 0 ]; then
  echo -e "${RED}prose-check FAILED${NC}"
  exit 1
fi
echo -e "${GREEN}prose-check OK${NC} (A/B/C/D/E/F all green — generated==regen, no prose fields, unique test ids, mirror wall current, ruling markers live, no tilde in a .k)"
