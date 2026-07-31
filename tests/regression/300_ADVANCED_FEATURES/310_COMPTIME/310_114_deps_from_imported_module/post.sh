#!/bin/bash
set -e

OUT=$(koruc input.kz deps 2>&1)

echo "$OUT" | grep -q "libfromentry" || { echo "FAIL: entry-file dependency missing"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "libfromimport" || { echo "FAIL: imported-module dependency missing — the scan is one level deep"; echo "$OUT"; exit 1; }

echo "=== Test passed: deps reached through the imported module ==="
