#!/bin/bash
# Post-validation for Profile metatype runtime test
# Validates that runtime timestamps are captured and output is correct

# Check that actual.txt exists
if [ ! -f actual.txt ]; then
    echo "ERROR: actual.txt not found"
    exit 1
fi

# Expected output pattern (timestamps will vary):
# Hello executed
# Profile: input:hello.done -> input:goodbye @ <non-zero timestamp>
# Goodbye executed
# Profile: input:goodbye.done -> terminal @ <non-zero timestamp>

# Check for event execution messages
if ! grep -q "Hello executed" actual.txt; then
    echo "ERROR: Missing 'Hello executed' message"
    exit 1
fi

if ! grep -q "Goodbye executed" actual.txt; then
    echo "ERROR: Missing 'Goodbye executed' message"
    exit 1
fi

# Check for Profile messages with correct transitions (with module qualifiers)
if ! grep -q "Profile: input:hello\.done -> input:goodbye @" actual.txt; then
    echo "ERROR: Missing 'Profile: input:hello.done -> input:goodbye' transition"
    exit 1
fi

if ! grep -q "Profile: input:goodbye\.done -> terminal @" actual.txt; then
    echo "ERROR: Missing 'Profile: input:goodbye.done -> terminal' transition"
    exit 1
fi

# Extract timestamps and verify they're non-zero (proving runtime capture)
TIMESTAMP1=$(grep "Profile: input:hello\.done -> input:goodbye @" actual.txt | sed 's/.*@ //')
TIMESTAMP2=$(grep "Profile: input:goodbye\.done -> terminal @" actual.txt | sed 's/.*@ //')

if [ -z "$TIMESTAMP1" ] || [ "$TIMESTAMP1" = "0" ]; then
    echo "ERROR: First timestamp is zero or missing (expected runtime capture)"
    exit 1
fi

if [ -z "$TIMESTAMP2" ] || [ "$TIMESTAMP2" = "0" ]; then
    echo "ERROR: Second timestamp is zero or missing (expected runtime capture)"
    exit 1
fi

# Success! Runtime profiling is working correctly
echo "✓ All Profile messages present"
echo "✓ Transitions correct (input:hello→input:goodbye→terminal)"
echo "✓ Runtime timestamps captured (non-zero values)"
exit 0
