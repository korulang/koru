#!/usr/bin/env sh
# Build and run the three-layout store benchmark.
# Usage: ./run.sh
#
# `--release=fast` is load-bearing: `koruc build` defaults to Debug, which
# inflates per-row call overhead and flattens the layout differences. The
# numbers in README.md are ReleaseFast.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
KORUC="$ROOT/../../../zig-out/bin/koruc"

if [ ! -x "$KORUC" ]; then
  echo "koruc not built (zig build); run from the repo root first" >&2
  exit 1
fi

( cd "$ROOT" && "$KORUC" build --release=fast main.k >/dev/null )
"$ROOT/a.out"
