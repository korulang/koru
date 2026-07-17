#!/bin/bash
# Validates the Chrome Tracing trace the profiler emitted: the program's real
# transitions are present, the JSON is closed, and the profiler is invisible
# to itself (its write-* events are inserted by [opaque] taps).
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

if ! grep -q '"input:get-number"' "$PROFILE_FILE"; then
    echo "ERROR: input:get-number transition missing"
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
