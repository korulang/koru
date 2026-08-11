#!/bin/bash
# The `vendor` COMMAND must see a binding declared inside an imported module.
#
# The compile-time half is pinned by the test body: the program builds, so the
# transform found and enforced the pin from `lib.k`. This asserts the other half,
# which failed independently — the command scanned `program.items`, which is the
# entry file alone, and answered "No vendored bindings declared" with exit 0 for
# a program whose vendored tree was under a live pin. A report that says nothing
# is declared, for a program that has one, is a green for an unchecked answer.

OUT=$(koruc input.k vendor check 2>&1)
STATUS=$?

if echo "$OUT" | grep -q "No vendored bindings declared"; then
    echo "✗ the command did not see the binding declared in lib.k"
    echo "$OUT" | tail -5
    exit 1
fi

if ! echo "$OUT" | grep -q "koru/vaxis"; then
    echo "✗ expected the report to name koru/vaxis"
    echo "$OUT" | tail -5
    exit 1
fi

if ! echo "$OUT" | grep -q "match their pin"; then
    echo "✗ expected a clean pin report"
    echo "$OUT" | tail -5
    exit 1
fi

if [ $STATUS -ne 0 ]; then
    echo "✗ vendor check exited $STATUS on a clean pin"
    exit 1
fi

echo "PASS: the command reports a module-declared binding"
exit 0
