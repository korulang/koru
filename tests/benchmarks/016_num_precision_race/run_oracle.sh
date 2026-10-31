#!/bin/bash
# Independent oracle: sympy/mpmath verify the recorded koru outputs.
# Needs a python with sympy+mpmath importable — nix store paths are
# self-discovered by the script; run with the newest python available.
# Usage: ./run_oracle.sh [koru_output_file]   (default: ./koru.out)
set -e
cd "$(dirname "$0")"
KORU_OUT="${1:-koru.out}"
PY="$(ls /nix/store/*-python3-3.1[0-9]*/bin/python3 2>/dev/null | sort | tail -1)"
PY="${PY:-python3}"
exec "$PY" sympy_oracle.py "$KORU_OUT"
