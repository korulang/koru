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

echo ""
if [ "$fail" -ne 0 ]; then
  echo -e "${RED}prose-check FAILED${NC}"
  exit 1
fi
echo -e "${GREEN}prose-check OK${NC} (A/B/C all green — generated==regen, no prose fields, all test ids unique)"
