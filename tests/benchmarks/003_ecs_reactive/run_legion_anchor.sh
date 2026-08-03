#!/usr/bin/env sh
set -eu

# legion is a boids-only arm: it exists to test whether legion's archetype
# packing advantage on contiguous two-stream iteration survives a workload whose
# traffic is mostly random scatter/gather into a side grid. It is deliberately
# not in run.sh's main loop, which walks every scenario across every arm.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

cargo run --release --quiet --manifest-path "$ROOT/rust_legion/Cargo.toml" -- \
  --scenario boids --entities 100000 --frames 100 --observers 25
