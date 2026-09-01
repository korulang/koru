#!/bin/bash
# Validates Chrome trace: multiline [profile]import kept std/profiler live.
PROFILE_FILE="/tmp/koru_profile.json"

if [ ! -f "$PROFILE_FILE" ]; then
    echo "ERROR: no trace at $PROFILE_FILE"
    exit 1
fi

if ! grep -q '"traceEvents"' "$PROFILE_FILE"; then
    echo "ERROR: missing traceEvents"
    cat "$PROFILE_FILE"
    exit 1
fi

if ! grep -q '"input:ping"' "$PROFILE_FILE"; then
    echo "ERROR: input:ping transition missing"
    cat "$PROFILE_FILE"
    exit 1
fi

if ! grep -q '"std.io:print.ln"' "$PROFILE_FILE"; then
    echo "ERROR: std.io:print.ln transition missing"
    cat "$PROFILE_FILE"
    exit 1
fi

if ! grep -q '^]}$' "$PROFILE_FILE"; then
    echo "ERROR: JSON not closed"
    cat "$PROFILE_FILE"
    exit 1
fi

if grep -qE 'write-event|write-header|write-footer' "$PROFILE_FILE"; then
    echo "ERROR: profiler observed itself"
    cat "$PROFILE_FILE"
    exit 1
fi

echo "✓ trace valid"
exit 0
