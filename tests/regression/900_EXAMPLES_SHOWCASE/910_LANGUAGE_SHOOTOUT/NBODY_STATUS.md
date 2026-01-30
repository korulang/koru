# N-Body Benchmark Status

**Last benchmarked:** 2026-01-30
**Test:** 50M iterations, 5 bodies (solar system)
**Machine:** Apple Silicon (ARM64)
**Tool:** hyperfine (3 warmup, 10 runs)

## Results: Koru Matches Hand-Optimized Zig

```
| Implementation     |   Time  | vs Zig (opt) | Notes                              |
|--------------------|---------|--------------|-------------------------------------|
| Zig (optimized)    | 1.285s  | 1.00x        | Hand-tuned: @setFloatMode, dsq*sqrt |
| Koru               | 1.306s  | 1.02x        | Compiler-generated, essentially tied |
| Rust               | 1.343s  | 1.05x        | split_at_mut pattern for noalias    |
| C                  | 1.469s  | 1.14x        | -O3 -ffast-math -march=native       |
| Zig (idiomatic)    | 2.023s  | 1.57x        | What a good developer would write   |
```

**The story:**
- Koru is **within 2% of hand-optimized Zig** - essentially tied
- Koru is **3% faster than Rust**
- Koru is **11% faster than optimized C**
- Koru is **57% faster than idiomatic Zig**

## What Makes This Honest

All implementations use equivalent optimizations and structurally similar code:

| Implementation | Compiler | Optimization Flags | Algorithm |
|----------------|----------|-------------------|-----------|
| Koru | Zig 0.15.1 | `-O ReleaseFast` + `@setFloatMode(.optimized)` | nested loops, dsq*sqrt |
| Zig (optimized) | Zig 0.15.1 | `-O ReleaseFast` + `@setFloatMode(.optimized)` | nested loops, dsq*sqrt, fixed arrays |
| Zig (idiomatic) | Zig 0.15.1 | `-O ReleaseFast` only | while loops, slices, naive algo |
| Rust | rustc 1.90.0-nightly | `-C opt-level=3 -C target-cpu=native` | split_at_mut for noalias, dsq*sqrt |
| C | Apple Clang 17.0.0 | `-O3 -ffast-math -fomit-frame-pointer -march=native` | nested loops, restrict, dsq*sqrt |

### Rust: split_at_mut Pattern

The Rust implementation uses `split_at_mut` - the idiomatic safe Rust way to express non-aliasing mutations:

```rust
#[inline(always)]
fn advance(bodies: &mut [Body; N]) {
    for i in 0..N-1 {
        let (left, right) = bodies.split_at_mut(i + 1);
        let b1 = &mut left[i];
        for b2 in right.iter_mut() {
            update_pair(b1, b2);
        }
    }
}
```

This is structurally similar to Koru/Zig and allows the Rust compiler to prove non-aliasing.

### Zig (idiomatic) - The Fair Baseline

The idiomatic Zig is what a competent developer writes without performance tuning:
- Uses slices (`[]Body`) instead of fixed arrays (`*[5]Body`)
- Uses while loops with manual index management
- Uses naive `distance * distance * distance` instead of `dsq * sqrt(dsq)`
- No `@setFloatMode(.optimized)`

This represents "normal good code" - correct, readable, maintainable.

## What Koru Does Automatically

You write:
```koru
~std.kernel:pairwise {
    const dx = k.x - k.other.x;
    const dsq = dx*dx + dy*dy + dz*dz;
    const mag = DT / (dsq * @sqrt(dsq));
    k.vx -= dx * k.other.mass * mag;
    k.other.vx += dx * k.mass * mag;
}
```

And get hand-optimized performance automatically. The kernel abstraction:
- Knows `k` and `k.other` are different elements (noalias)
- Generates pointer-based inline functions
- Uses static backing when init size is known
- Enables `@setFloatMode(.optimized)`

**The DSL advantage:** Natural Koru code matches hand-optimized Zig/Rust.

## The C Gap

C is 14% slower despite having all optimizations applied:
- `restrict` pointer qualifier
- Fixed loop bounds (0..5)
- `-ffast-math` for aggressive FP optimization
- `static inline` for inlining

This gap appears fundamental to C's ability to communicate aliasing information to LLVM compared to Zig's pointer types.

## Running the Benchmark

```bash
cd tests/regression/900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT
./benchmark.sh 10 50000000
```

## Files

- `2101g_nbody_kernel_pairwise/` - Koru kernel:pairwise implementation
- `2101_nbody_optimized/reference/baseline.zig` - Hand-optimized Zig
- `2101_nbody_optimized/reference/baseline_unsafe.rs` - Rust with split_at_mut
- `2101_nbody/reference/baseline.zig` - Idiomatic Zig
- `2101_nbody_optimized/reference/reference.c` - C implementation

## Key Takeaway

**Koru's kernel system automatically generates expert-level optimizations.** The 57% gap between idiomatic and optimized Zig shows how much performance is left on the table by "normal" code. Koru closes that gap without requiring manual tuning.

All implementations now use structurally similar code (nested loops with explicit noalias patterns), making the comparison fair and honest.
