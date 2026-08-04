#!/usr/bin/env bash
# Install the membrane + worldmodel git discipline into ANY repo. Ubiquitous by
# design — a no-brainer to drop on any repo:
#   commit-msg   — the gate (universal World Model signal + OKF-aware lineage)
#   post-commit  — the faucet (routes belief-class signals to the corpus inbox)
#   .membrane    — store pointer (which corpus this repo's beliefs flow into)
#   concepts/    — the OKF store, scaffolded so the corpus is ready immediately
#
# By default a repo is its OWN self-contained corpus (zero config). Pass a shared
# corpus path to make it a consumer that routes its beliefs into a family store.
#
# Usage:
#   hooks/install.sh                       # install into THIS repo (self corpus)
#   hooks/install.sh /path/to/repo         # repo as its OWN self-contained corpus
#   hooks/install.sh /path/to/repo /corpus # repo routes its beliefs to <corpus>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CORPUS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET="$(cd "${1:-$CORPUS_ROOT}" && pwd)"
STORE="$(cd "${2:-$TARGET}" && pwd)"     # default: self-contained (store = repo)

HOOKS="$(git -C "$TARGET" rev-parse --absolute-git-dir)/hooks"
mkdir -p "$HOOKS" "$STORE/concepts"
[ -e "$STORE/concepts/.gitkeep" ] || : > "$STORE/concepts/.gitkeep"
for h in commit-msg commit-msg.cjs post-commit post-commit.cjs; do
  cp "$HERE/$h" "$HOOKS/$h"; chmod +x "$HOOKS/$h"
done
printf '%s\n' "$STORE" > "$TARGET/.membrane"

echo "installed commit-msg + post-commit -> $HOOKS"
echo "store pointer                       -> $TARGET/.membrane ($STORE)"
if [ "$STORE" = "$TARGET" ]; then
  echo "topology: self-contained (this repo is its own corpus)"
else
  echo "topology: consumer → shared corpus ($STORE)"
fi

# --- seed the universal belief-class signals (the interlock's vocabulary) ---
# The commit-msg interlock treats a Signal as belief-class iff its interface file
# declares `membrane: true`. The three discipline verbs — contradiction, correction,
# regime-change — are universal (not project-specific), so a WELL-FORMED repo must
# ship them; without them the interlock silently never fires and belief-changes leak
# past the gate. Copy into the repo the hook reads signals from (cwd = TARGET). Never
# clobber a gardened signal — only add what's missing.
if [ -d "$HERE/signals" ]; then
  mkdir -p "$TARGET/signals"
  for sig in "$HERE"/signals/*.signal; do
    [ -e "$sig" ] || continue
    dest="$TARGET/signals/$(basename "$sig")"
    [ -e "$dest" ] || cp "$sig" "$dest"
  done
  echo "belief-class signals                 -> $TARGET/signals/ (contradiction, correction, regime-change)"
fi

# --- auto-build the universal commit-cadence instrument for this repo ---
# Every repo has commits, so the cadence watchdog is universal. Ship its source
# into the repo and compile cc_live THROUGH the engine, so this repo's commit-msg
# hook computes a real measured signal too — not just the declarative gate.
# Best-effort: needs the WMFX engine; if absent, the gate still works and the
# measured layer simply stays off (the hook skips a missing cc_live silently).
SRC="$CORPUS_ROOT/models/commit_cadence"
DST="$TARGET/models/commit_cadence"
if [ -d "$SRC" ]; then
  if [ "$TARGET" != "$CORPUS_ROOT" ]; then
    mkdir -p "$DST"
    for f in model.wmfx cc_live.zig oracle.zig run.zig gitcsv.mjs build.sh .gitignore; do
      [ -f "$SRC/$f" ] && cp "$SRC/$f" "$DST/$f"
    done
  fi
  if command -v zig >/dev/null 2>&1 && bash "$DST/build.sh" >/dev/null 2>&1; then
    echo "instrument: commit-cadence built -> $DST/cc_live (engine-computed measured signals ON)"
  else
    echo "instrument: commit-cadence NOT built (engine unavailable) — gate works; measured layer off"
  fi
fi
