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

# The program envelope: koru:start/koru:end are meta-events, not transitions.
# They anchor the trace as ph:"i" instants on their own lane, with one
# synthesized "program" span between them — and must never appear as
# transition rows.
if ! grep -q '"name":"koru:start","cat":"meta","ph":"i"' "$PROFILE_FILE"; then
    echo "ERROR: koru:start meta anchor missing"
    cat "$PROFILE_FILE"
    exit 1
fi

if ! grep -q '"name":"koru:end","cat":"meta","ph":"i"' "$PROFILE_FILE"; then
    echo "ERROR: koru:end meta anchor missing"
    cat "$PROFILE_FILE"
    exit 1
fi

if ! grep -q '"name":"program","cat":"meta","ph":"X"' "$PROFILE_FILE"; then
    echo "ERROR: synthesized program span missing"
    cat "$PROFILE_FILE"
    exit 1
fi

if grep -qE '"name":"koru:[^"]*","cat":"transition"' "$PROFILE_FILE"; then
    echo "ERROR: meta-event recorded as a transition"
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
