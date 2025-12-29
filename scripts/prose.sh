#!/bin/bash
# scripts/prose.sh
# Unified Semantic Memory Sync for Koru

# Configuration
CLAUDE_PROJECT_DIR="/Users/larsde/.claude/projects/-Users-larsde-src-koru"
ANTIGRAVITY_DIR="/Users/larsde/.gemini/antigravity/brain/47228cb5-86e5-4a07-9273-384955f2bfd7"
SESSION_ID="antigravity-$(date +%s)"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
OUTPUT_FILE="${CLAUDE_PROJECT_DIR}/${SESSION_ID}.jsonl"

echo "🧬 Synthesizing Multi-AI Memory (prose)..."

# 1. Extract Git Context
echo "   - Extracting Git context..."
GIT_LOG=$(git log -n 5 --pretty=format:"* %s (%h)" 2>/dev/null)
if [ -z "$GIT_LOG" ]; then
    GIT_LOG="No recent commits found."
fi

# 2. Extract Antigravity Session Memory
echo "   - Extracting Antigravity session memory..."
if [ -f "${ANTIGRAVITY_DIR}/task.md" ] && [ -f "${ANTIGRAVITY_DIR}/walkthrough.md" ]; then
    TASK_MD=$(cat "${ANTIGRAVITY_DIR}/task.md")
    WALKTHROUGH_MD=$(cat "${ANTIGRAVITY_DIR}/walkthrough.md")
else
    echo "   ⚠️  Antigravity session files not found. Skipping session info."
    TASK_MD="N/A"
    WALKTHROUGH_MD="N/A"
fi

# 3. Construct the "User" and "Assistant" messages
# We'll represent the session as a user asking for a summary and assistant providing it.
# This makes it easy for claude-prose's LLM-based evolution to digest.

UUID_USER=$(uuidgen | tr '[:upper:]' '[:lower:]')
UUID_ASSISTANT=$(uuidgen | tr '[:upper:]' '[:lower:]')

# Escape backslashes and double quotes for JSON
escape_json() {
    printf '%s' "$1" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))' | sed 's/^"//;s/"$//'
}

ESC_TASK_MD=$(escape_json "$TASK_MD")
ESC_WALKTHROUGH_MD=$(escape_json "$WALKTHROUGH_MD")
ESC_GIT_LOG=$(escape_json "$GIT_LOG")

USER_CONTENT="Summarize the recent work done in the Antigravity session and Git history."
ASSISTANT_CONTENT="# ANTIGRAVITY SESSION SUMMARY\n\n## Tasks Accomplished\n${ESC_TASK_MD}\n\n## Technical Walkthrough\n${ESC_WALKTHROUGH_MD}\n\n## Recent Git History\n${ESC_GIT_LOG}\n\nThis session focused on fixing the depth-first transform order and improving the regression test runner."

# Write User Message
echo "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"${USER_CONTENT}\"},\"uuid\":\"${UUID_USER}\",\"timestamp\":\"${TIMESTAMP}\",\"sessionId\":\"${SESSION_ID}\",\"project\":\"/Users/larsde/src/koru\"}" > "$OUTPUT_FILE"

# Write Assistant Message
echo "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"${ASSISTANT_CONTENT}\"}]},\"uuid\":\"${UUID_ASSISTANT}\",\"parentUuid\":\"${UUID_USER}\",\"timestamp\":\"${TIMESTAMP}\",\"sessionId\":\"${SESSION_ID}\"}" >> "$OUTPUT_FILE"

# 4. Trigger claude-prose evolution
echo "   - Triggering claude-prose evolution..."
claude-prose evolve --project /Users/larsde/src/koru

echo "✅ Memory unified and evolved for project: koru"
