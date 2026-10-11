#!/bin/bash
set -u
cd "$(dirname "$0")"

# std/package declares `i`/`install`. `koruc <file> install` dispatches on
# this input (proven below), so `help` claiming none exist is a false report.

OUT=$(koruc "$KORU_INPUT" help 2>&1) || { echo "FAIL: help exited non-zero"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "install" || {
    echo "FAIL: 'help' does not list 'install', though install dispatches on this file"
    echo "$OUT"
    exit 1
}

# Control: install really does dispatch (it announces itself and completes).
OUT2=$(koruc "$KORU_INPUT" install 2>&1)
echo "$OUT2" | grep -q "Running command: install" || {
    echo "FAIL: control — install did not dispatch; the pin's premise moved"
    echo "$OUT2"
    exit 1
}

echo "=== Test passed: help lists commands the program's imports declare ==="
