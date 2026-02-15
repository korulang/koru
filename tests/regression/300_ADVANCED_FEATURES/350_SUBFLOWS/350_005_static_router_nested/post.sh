#!/bin/bash
# Post-validation: verify the static_router transform generated the routes file
if [ ! -f "generated/site_routes.zig" ]; then
    echo "FAIL: generated/site_routes.zig was not created"
    exit 1
fi

# Verify it contains route entries for our testdata files
if ! grep -q "index.html" "generated/site_routes.zig"; then
    echo "FAIL: generated/site_routes.zig missing index.html route"
    exit 1
fi

if ! grep -q "about.html" "generated/site_routes.zig"; then
    echo "FAIL: generated/site_routes.zig missing about.html route"
    exit 1
fi

echo "PASS: generated routes file contains expected routes"
exit 0
