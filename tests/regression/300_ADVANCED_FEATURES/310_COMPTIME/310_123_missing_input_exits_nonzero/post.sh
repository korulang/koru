#!/bin/bash
set -e

# Missing input is a user error. Printing it and exiting 0 is the same
# observation as success — Q1 in challenges/018_FIX_QUEUE.md.

if OUT=$(koruc run 2>&1); then
    echo "FAIL: 'koruc run' with no file exited 0"
    echo "$OUT"
    exit 1
fi
echo "$OUT" | grep -q "no input file specified" || { echo "FAIL: koruc run: no missing-file diagnostic"; echo "$OUT"; exit 1; }

if OUT=$(koruc build 2>&1); then
    echo "FAIL: 'koruc build' with no file exited 0"
    echo "$OUT"
    exit 1
fi
echo "$OUT" | grep -q "no input file specified" || { echo "FAIL: koruc build: no missing-file diagnostic"; echo "$OUT"; exit 1; }

# Controls: help, no-args usage, and the toolchain check are still success.
koruc --help > /dev/null 2>&1 || { echo "FAIL: 'koruc --help' broke"; exit 1; }
koruc > /dev/null 2>&1 || { echo "FAIL: bare 'koruc' (usage) broke"; exit 1; }
koruc deps > /dev/null 2>&1 || { echo "FAIL: bare 'koruc deps' broke"; exit 1; }

echo "=== Test passed: missing input exits non-zero; help and deps still succeed ==="
