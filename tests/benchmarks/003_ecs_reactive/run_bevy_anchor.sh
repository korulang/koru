#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

cargo run --release --quiet --manifest-path "$ROOT/rust_bevy/Cargo.toml" -- \
  --scenario archetype_churn_world --entities 100000 --frames 100 --observers 25

