# 5-Field Statistics Benchmark Results

Measured with Hyperfine on Apple Silicon (M1/M2/M3).

## Fast Versions (5 warmup, 5 runs)

| Command | Mean [ms] | Min [ms] | Max [ms] | Relative |
|:---|---:|---:|---:|---:|
| `./zig_baseline 100000000` | 48.7 ± 0.2 | 48.4 | 48.8 | 1.00 |
| `./a.out 100000000` (Koru) | 49.1 ± 0.9 | 48.5 | 50.6 | 1.01 ± 0.02 |
| `./haskell_strict` | 74.0 ± 4.9 | 68.8 | 78.7 | 1.52 ± 0.10 |

## Tuple Version (1 warmup, 3 runs)

| Command | Mean [s] | Min [s] | Max [s] | vs Koru |
|:---|---:|---:|---:|---:|
| `./haskell_stats` (tuple) | 63.8 ± 2.6 | 61.1 | 66.2 | 1300x slower |

## Summary

- **Koru matches hand-written Zig** (within measurement noise)
- **Haskell strict data type**: 1.5x slower (respectable!)
- **Haskell tuple**: 1300x slower (catastrophic)

The "obvious" Haskell code (tuple fold) is 1300x slower than the optimized version.
In Koru, the obvious code IS the fast code.

## Reproduction

\`\`\`bash
# Build all versions
ghc -O2 haskell_stats.hs -o haskell_stats
ghc -O2 haskell_strict.hs -o haskell_strict
zig build-exe zig_baseline.zig -O ReleaseFast -femit-bin=zig_baseline
koruc koru_stats.kz  # produces a.out

# Run benchmarks
hyperfine --warmup 2 --runs 5 \
  './a.out 100000000' \
  './zig_baseline 100000000' \
  './haskell_strict'

hyperfine --warmup 1 --runs 3 './haskell_stats'
\`\`\`
