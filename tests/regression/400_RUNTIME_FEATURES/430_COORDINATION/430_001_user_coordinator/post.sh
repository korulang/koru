#!/bin/bash
# Verify that the custom coordinator ran by checking for its metrics string

if grep -q "User-controlled pipeline: 3 passes" backend.err; then
    echo "✓ Custom coordinator metrics found in backend.err"
    exit 0
else
    echo "✗ Custom coordinator metrics NOT found - default coordinator may have run instead!"
    exit 1
fi
