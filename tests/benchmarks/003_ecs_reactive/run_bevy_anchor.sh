#!/usr/bin/env sh
# The archetype-churn anchor. Two arms, not one: bevy_ecs and koru_store.
#
# This scenario is NOT in run.sh, and that is deliberate — the Zig baseline exits
# 1 with error.UnknownScenario for it and run.sh is `set -eu`, so it would abort
# the whole suite. It lives here instead.
#
# The two sinks MUST be identical. That is the entire point of the scenario: it
# tests a RULING (Koru has no archetypes and does not need them) rather than
# adding coverage, and the sink is the only evidence the two implementations did
# the same work. A timing without an agreeing sink here means nothing.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
KORUC="$ROOT/../../../zig-out/bin/koruc"
KORU_DIR="$ROOT/koru_store"
ENTITIES="${ENTITIES:-100000}"
FRAMES="${FRAMES:-100}"

cargo run --release --quiet --manifest-path "$ROOT/rust_bevy/Cargo.toml" -- \
  --scenario archetype_churn_world --entities "$ENTITIES" --frames "$FRAMES" --observers 25

if [ -x "$KORUC" ]; then
  ( cd "$KORU_DIR" && "$KORUC" build main.k >/dev/null )
  "$KORU_DIR/a.out" --scenario archetype_churn_world \
    --entities "$ENTITIES" --frames "$FRAMES" --observers 25
else
  echo "koruc not built (zig build); skipped Koru arm" >&2
fi
