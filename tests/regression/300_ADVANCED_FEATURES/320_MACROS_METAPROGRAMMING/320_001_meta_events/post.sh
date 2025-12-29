#!/bin/bash
# Post-execution validation for meta-events test
# Verifies that Chrome Tracing JSON was created and is valid

PROFILE_FILE="/tmp/koru_profile.json"

# Verify profile file was created
if [ ! -f "$PROFILE_FILE" ]; then
    echo "ERROR: Profile file not created at $PROFILE_FILE"
    exit 1
fi

# Verify JSON structure
if ! grep -q '"traceEvents"' "$PROFILE_FILE"; then
    echo "ERROR: Invalid profile format - missing traceEvents"
    cat "$PROFILE_FILE"
    exit 1
fi

# Verify koru:start event exists
if ! grep -q '"koru:start"' "$PROFILE_FILE"; then
    echo "ERROR: koru:start event missing"
    cat "$PROFILE_FILE"
    exit 1
fi

# Verify koru:end event exists
if ! grep -q '"koru:end"' "$PROFILE_FILE"; then
    echo "ERROR: koru:end event missing"
    cat "$PROFILE_FILE"
    exit 1
fi

# Verify hello event exists
if ! grep -q '"hello"' "$PROFILE_FILE"; then
    echo "ERROR: hello event missing"
    cat "$PROFILE_FILE"
    exit 1
fi

# Verify JSON is well-formed (has both opening and closing)
if ! grep -q '^]}$' "$PROFILE_FILE"; then
    echo "ERROR: JSON not properly closed"
    cat "$PROFILE_FILE"
    exit 1
fi

echo "✓ Profile generated at $PROFILE_FILE"
echo "  Open chrome://tracing and load this file to view the execution trace!"

exit 0
