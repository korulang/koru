# N-Body Benchmark Status

**Last benchmarked:** 2026-01-23
**Test:** 50M iterations, 5 bodies (solar system)

## Current Rankings

| Rank | Implementation | Time | vs Zig |
|------|---------------|------|--------|
| 1 | Rust | 1.355s | 0.96x |
| 2 | Zig (forloop) | 1.414s | 1.00x |
| 3 | **Koru (arrayed capture)** | **1.429s** | **1.01x** |
| 4 | Koru (subflow) | 1.455s | 1.03x |
| 5 | C | 1.971s | 1.39x |
| 6 | Koru (wrapped Zig) | 2.071s | 1.46x |
| 7 | Koru (scalar capture) | 3.374s | 2.39x |

## Best Koru Implementation

**Winner: `2101f_nbody_arrayed_capture`** - Only 1% behind Zig baseline.

Key technique: Use `[5][3]f64` array instead of 15 scalar fields.
```koru
captured { dv[i][0]: acc.dv[i][0] - f.fx*f.mj, dv[j][0]: acc.dv[j][0] + f.fx*f.mi }
```
This generates direct array writes without conditionals.

## What We're Up Against

**Rust (1.355s)** - Uses SIMD-style manual optimizations. ~4% faster than Zig forloop.

**Zig forloop (1.414s)** - Clean nested loops with direct struct writes:
```zig
bodies[i].vx -= dx * bodies[j].mass * mag;
bodies[j].vx += dx * bodies[i].mass * mag;
```

## Test Variants Explained

| Test | Description | Status |
|------|-------------|--------|
| `2101_nbody` | Original baseline | SKIP |
| `2101_nbody_optimized` | Hand-optimized | SKIP |
| `2101b_nbody_granular` | Fine-grained events | PASS |
| `2101c_nbody_extreme` | Optimization experiments | SKIP |
| `2101d_nbody_pure_capture` | Wrapped Zig with ~for | PASS |
| `2101e_nbody_pure_scalar` | True capture, scalar fields (SLOW) | PASS |
| **`2101f_nbody_arrayed_capture`** | **Arrayed capture (FAST)** | **PASS** |
| `2101g_nbody_subflow` | Subflow-based | SKIP |

## Performance Gap Analysis

- **Koru vs Zig: 1%** - Essentially matched. No DSL overhead.
- **Koru vs Rust: 5%** - Rust has manual SIMD opts we don't replicate.
- **Scalar vs Array capture: 2.4x** - Conditionals kill performance.

## Next Steps

1. **Kernel system** - Should match arrayed capture performance with cleaner syntax
2. **Investigate Rust gap** - What SIMD tricks are they using?
3. **Auto-vectorization** - Can we hint Zig to vectorize the inner loop?

## Running Benchmarks

```bash
cd tests/regression/900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT
hyperfine --warmup 2 --runs 5 \
    "./2101f_nbody_arrayed_capture/a.out 50000000" \
    "./2101_nbody/reference/nbody-zig-forloop 50000000" \
    "./2101_nbody/reference/nbody-rust 50000000"
```
