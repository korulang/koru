#!/bin/bash
# Validates the Chrome trace under nested label loops: the program's loop
# transitions are captured, the JSON is closed, and the profiler is invisible
# to itself.
if [ -f "koru_profile.snapshot.json" ]; then
    PROFILE_FILE="koru_profile.snapshot.json"
else
    PROFILE_FILE="/tmp/koru_profile.json"
fi

if [ ! -f "$PROFILE_FILE" ]; then
    echo "ERROR: no trace at $PROFILE_FILE"
    exit 1
fi

if ! grep -q '"traceEvents"' "$PROFILE_FILE"; then
    echo "ERROR: missing traceEvents"
    cat "$PROFILE_FILE"
    exit 1
fi

if ! grep -q '"input:start"' "$PROFILE_FILE"; then
    echo "ERROR: input:start transition missing"
    cat "$PROFILE_FILE"
    exit 1
fi

if ! grep -q '"input:outer"' "$PROFILE_FILE"; then
    echo "ERROR: input:outer transition missing"
    cat "$PROFILE_FILE"
    exit 1
fi

if ! grep -q '"input:inner"' "$PROFILE_FILE"; then
    echo "ERROR: input:inner transition missing"
    cat "$PROFILE_FILE"
    exit 1
fi

# Loop iterations: 3 outer x 2 inner should produce well over 5 transitions
EVENT_COUNT=$(grep -c '"name":' "$PROFILE_FILE")
if [ "$EVENT_COUNT" -lt 5 ]; then
    echo "ERROR: Expected at least 5 events, found $EVENT_COUNT"
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

echo "✓ Profile generated at $PROFILE_FILE with $EVENT_COUNT events"
exit 0
