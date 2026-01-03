#!/bin/bash
# Post-validation: Verify auto-dispose warning was emitted
#
# This test passes if:
# 1. Compilation succeeded (handled by test runner)
# 2. Warning about auto-dispose insertion is present in backend.err
#
# Note: The warning is emitted during backend execution (not frontend),
# so we check backend.err, not compile_kz.err

# Check for the warning in backend.err (backend execution stderr)
if grep -q "warning\[AUTO-DISPOSE\]" backend.err 2>/dev/null; then
    echo "Found auto-dispose warning in backend.err"
    exit 0
else
    echo "ERROR: Expected warning[AUTO-DISPOSE] in backend.err"
    echo "Contents of backend.err:"
    head -50 backend.err 2>/dev/null || echo "(file not found)"
    exit 1
fi
