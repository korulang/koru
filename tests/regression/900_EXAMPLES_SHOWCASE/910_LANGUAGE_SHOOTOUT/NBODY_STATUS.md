# N-Body Benchmark Status

**Last benchmarked:** 2026-01-23
**Test:** 50M iterations, 5 bodies (solar system)
**Machine:** Apple Silicon (ARM64)

## Current Rankings

| Rank | Implementation | Time | vs Rust |
|------|---------------|------|---------|
| 1 | **Rust** | **1.36s** | **1.00x** |
| 2 | Zig SIMD | 1.41s | 1.04x |
| 3 | Zig forloop | 1.42s | 1.04x |
| 4 | **Koru arrayed capture** | **1.43s** | **1.05x** |
| 5 | Zig SoA | 1.53s | 1.13x |

## The 4% Gap - Unsolved

We cannot beat Rust. Consistently 4% behind despite trying:

| Optimization | Result |
|-------------|--------|
| SoA layout | **Slower** (cache locality worse for N=5) |
| Loop splitting (Rust-style) | No change |
| Manual unrolling | **Slower** (code bloat) |
| Comptime inline for | No change |
| Explicit @Vector(4, f64) SIMD | 3% gain, still 4% behind |
| Precomputed mass vectors | Slower |
| -mcpu=native | Marginal |

## Best Koru Implementation

**`2101f_nbody_arrayed_capture`** - 5% behind Rust, uses array indexing:
```koru
captured { dv[i][0]: acc.dv[i][0] - f.fx*f.mj }
```

## Experimental Files

Created during optimization attempts (in this directory):
- `nbody_handopt.zig` - SoA + manual unroll (slower)
- `nbody_handopt2.zig` - SoA only (slower)
- `nbody_split.zig` - Rust-style loop splitting (no change)
- `nbody_simd.zig` - @Vector(4,f64) for 3D ops (best Zig: 1.41s)
- `nbody_simd2.zig` - SIMD + comptime unroll (no change)
- `nbody_simd3.zig` - Precomputed mass vectors (slower)

## Hypothesis: Why Rust Wins

The 4% gap persists across all Zig approaches. Possible causes:
1. **LLVM version differences** - Rust/Zig use different LLVM versions
2. **Aliasing analysis** - Rust's borrow checker proves non-aliasing
3. **Inlining heuristics** - Different default inline thresholds
4. **Memory model** - Rust may have tighter guarantees

## For Codex

**Challenge:** Beat Rust (1.36s) with Zig or prove it's impossible.

What we know:
- N=5 is too small for SoA/SIMD to help significantly
- The inner loop is already very tight
- Rust's `split_first_mut()` pattern may be key
- This is ARM64 (NEON, not AVX)

Ideas not yet tried:
- Inline assembly for the hot loop
- Different loop structures (blocked, tiled)
- Reciprocal sqrt approximation
- Profile-guided optimization

## Running Benchmarks

```bash
cd tests/regression/900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT
hyperfine --warmup 3 --runs 10 \
    "./2101_nbody/reference/nbody-rust 50000000" \
    "./nbody-simd 50000000" \
    "./2101f_nbody_arrayed_capture/a.out 50000000"
```
