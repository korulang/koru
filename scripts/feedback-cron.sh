#!/bin/bash
# Morning Koru feedback triage — launchd wrapper.
# Runs Claude headless against scripts/feedback-cron-prompt.md, autonomously
# fixing safe feedback items (committed on a dated branch, never pushed) and
# triaging the rest, then posting a digest to Discord.
#
# Logs live OUTSIDE the repo (~/.koru-feedback-cron/) to keep git status clean.
set -uo pipefail

# launchd starts with a minimal environment — restore the PATH we need.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

KORU="$HOME/src/koru"
KORULANG="$HOME/src/korulang_org"
PROMPT_FILE="$KORU/scripts/feedback-cron-prompt.md"
LOG_DIR="$HOME/.koru-feedback-cron"
STAMP="$(date +%Y-%m-%d)"
LOG="$LOG_DIR/$STAMP.log"

mkdir -p "$LOG_DIR"
cd "$KORU" || exit 1

{
  echo "=== feedback-cron run $(date) ==="
} >> "$LOG" 2>&1

claude -p "$(cat "$PROMPT_FILE")" \
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
