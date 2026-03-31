#!/usr/bin/env bash
set -euo pipefail

echo "ASPIRATIONAL FAILURE: kernel scope still permits arbitrary stdlib events."
echo "Future behavior should reject: unsupported invocation 'std.io:print.ln' inside kernel scope"
exit 1
