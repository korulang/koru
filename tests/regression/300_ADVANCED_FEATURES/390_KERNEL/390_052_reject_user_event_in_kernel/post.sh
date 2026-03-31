#!/usr/bin/env bash
set -euo pipefail

echo "ASPIRATIONAL FAILURE: kernel scope still permits arbitrary user events."
echo "Future behavior should reject: unsupported invocation 'print_mass' inside kernel scope"
exit 1
