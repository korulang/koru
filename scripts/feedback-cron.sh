#!/bin/bash
# Morning Koru feedback triage — launchd wrapper.
# Runs Claude headless in a DEDICATED GIT WORKTREE (never the shared main
# checkout) against scripts/feedback-cron-prompt.md, autonomously fixing safe
# feedback items (committed on a dated branch, never pushed) and triaging the
# rest, then posting a digest to Discord.
#
# Why a worktree (2026-07-19): the job checks out a dated branch and commits to
# it. Doing that in ~/src/koru left the SHARED checkout parked on
# feedback-auto/*, corrupting whatever Lars (or another agent) had open there.
# The worktree isolates all branch/commit activity to $WT; the shared checkout
# is never touched.
#
# Logs live OUTSIDE the repo (~/.koru-feedback-cron/) to keep git status clean.
set -uo pipefail

# launchd starts with a minimal environment — restore the PATH we need.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

KORU="$HOME/src/koru"
KORULANG="$HOME/src/korulang_org"
PROMPT_FILE="$KORU/scripts/feedback-cron-prompt.md"
LOG_DIR="$HOME/.koru-feedback-cron"
WT="$LOG_DIR/worktree"          # stable path — referenced verbatim in the prompt
STAMP="$(date +%Y-%m-%d)"
BRANCH="feedback-auto/$STAMP"
LOG="$LOG_DIR/$STAMP.log"

mkdir -p "$LOG_DIR"

{
  echo "=== feedback-cron run $(date) ==="
} >> "$LOG" 2>&1

# --- Prepare an isolated worktree on today's dated branch ------------------
# Never operate in the shared main checkout. Tear down any stale worktree from a
# previous run, then create a fresh one off main (or reuse today's branch on a
# same-day re-run so its commits are preserved). The dated branch persists after
# the worktree is removed, so Lars can still review it.
{
  git -C "$KORU" worktree remove --force "$WT" 2>/dev/null || true
  git -C "$KORU" worktree prune

  if git -C "$KORU" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    # Re-run same day: reuse the existing dated branch, keep its commits.
    git -C "$KORU" worktree add "$WT" "$BRANCH"
  else
    # Fresh dated branch off main.
    git -C "$KORU" worktree add -b "$BRANCH" "$WT" main
  fi
} >> "$LOG" 2>&1
WT_RC=$?

if [ "$WT_RC" -ne 0 ] || [ ! -d "$WT" ]; then
  echo "=== worktree setup FAILED (rc=$WT_RC) at $(date); aborting ===" >> "$LOG" 2>&1
  WEBHOOK="$(grep -E '^DISCORD_STATUS_WEBHOOK=' "$KORULANG/.env.local" 2>/dev/null | cut -d= -f2- | tr -d '"')"
  if [ -n "$WEBHOOK" ]; then
    curl -sS -H "Content-Type: application/json" \
      -d "{\"content\": \"⚠️ feedback-cron could not create its worktree ($STAMP). Log: $LOG\"}" \
      "$WEBHOOK" >/dev/null 2>&1
  fi
  exit 1
fi

cd "$WT" || exit 1

# Runtime preamble — the strongest signal that the koru repo == this worktree,
# and that Step 5 must NOT switch branches (it already is on the dated branch).
PREAMBLE="RUNTIME CONTEXT (read this first). You are running headless in a DEDICATED GIT WORKTREE of the koru repo at $WT, already checked out on branch $BRANCH. This worktree IS your current working directory and the ONLY place you touch the koru repo. NEVER cd to ~/src/koru — that is the shared main checkout, and switching its branch corrupts other work. Do NOT run 'git switch', 'git checkout -b', or 'git worktree'; you are already on the correct dated branch, so Step 5 is only: stage and commit here. Everywhere the prompt below names the koru repo (~/src/koru), it means this worktree, $WT."

claude -p "$PREAMBLE"$'\n\n'"$(cat "$PROMPT_FILE")" \
  --add-dir "$KORULANG" \
  --permission-mode bypassPermissions \
  --model claude-opus-4-8 >> "$LOG" 2>&1
RC=$?

echo "=== claude exit $RC at $(date) ===" >> "$LOG" 2>&1

# Safety net: if Claude itself failed to run, the digest never got posted —
# ping Discord directly so the morning isn't silently broken.
if [ "$RC" -ne 0 ]; then
  WEBHOOK="$(grep -E '^DISCORD_STATUS_WEBHOOK=' "$KORULANG/.env.local" 2>/dev/null | cut -d= -f2- | tr -d '"')"
  if [ -n "$WEBHOOK" ]; then
    curl -sS -H "Content-Type: application/json" \
      -d "{\"content\": \"⚠️ feedback-cron failed to run ($STAMP) — claude exited $RC. Log: $LOG\"}" \
      "$WEBHOOK" >/dev/null 2>&1
  fi
fi

exit "$RC"
