#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUT="$ROOT/results.jsonl"
ZIG_BIN="$ROOT/zig_striped/zig_striped"
KORUC="$ROOT/../../../zig-out/bin/koruc"
KORU_DIR="$ROOT/koru_store"

: > "$OUT"

zig build-exe "$ROOT/zig_striped/src/main.zig" -O ReleaseFast -femit-bin="$ZIG_BIN"

SCENARIOS="spawn spawn_batch despawn add_remove query_get dense sparse schedule_empty fanout combat_world bevy_strength_world boids"

for scenario in $SCENARIOS; do
  frames=100
  if [ "$scenario" = "schedule_empty" ]; then
    frames=100000
  fi
  "$ZIG_BIN" --scenario "$scenario" --entities 100000 --frames "$frames" --observers 25 >> "$OUT"
done

if command -v cargo >/dev/null 2>&1; then
  for scenario in $SCENARIOS; do
    frames=100
    if [ "$scenario" = "schedule_empty" ]; then
      frames=100000
    fi
    cargo run --release --quiet --manifest-path "$ROOT/rust_bevy/Cargo.toml" -- \
      --scenario "$scenario" --entities 100000 --frames "$frames" --observers 25 >> "$OUT"
  done
else
  echo "cargo not found; skipped Bevy baseline" >&2
fi

# The Koru entry emits nothing for a scenario it has not ported yet — it
# refuses on stderr and exits 0 — so an absent line in results.jsonl means
# "not implemented", never "ran and produced nothing".
if [ -x "$KORUC" ]; then
  ( cd "$KORU_DIR" && "$KORUC" build main.k >/dev/null )
  for scenario in $SCENARIOS; do
    frames=100
    if [ "$scenario" = "schedule_empty" ]; then
      frames=100000
    fi
    "$KORU_DIR/a.out" --scenario "$scenario" --entities 100000 --frames "$frames" --observers 25 >> "$OUT"
  done
else
  echo "koruc not built (zig build); skipped Koru entry" >&2
fi

cat "$OUT"
