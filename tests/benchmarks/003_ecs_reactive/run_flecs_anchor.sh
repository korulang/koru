#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SRC="$ROOT/flecs_churn/main.c"
BIN="$ROOT/flecs_churn/flecs_churn"

cc -O3 -DNDEBUG "$SRC" -I/opt/homebrew/include -L/opt/homebrew/lib -lflecs -o "$BIN"
"$BIN" --entities 100000 --frames 100

