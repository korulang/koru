# N-Body Benchmark Status

**Last benchmarked:** 2026-01-30
**Test:** 50M iterations, 5 bodies (solar system)
**Machine:** Apple Silicon (ARM64)
**Tool:** hyperfine (3 warmup, 10 runs)

## Results: Koru Matches Hand-Optimized Zig

```
| Implementation     |   Time  | vs Zig (opt) | Notes                              |
|--------------------|---------|--------------|-------------------------------------|
| Zig (optimized)    | 1.276s  | 1.00x        | Hand-tuned: @setFloatMode, dsq*sqrt |
| Koru               | 1.294s  | 1.01x        | Compiler-generated, essentially tied |
| Rust               | 1.349s  | 1.06x        | Official benchmark game impl        |
| C                  | 1.467s  | 1.15x        | -O3 -ffast-math -march=native       |
| Zig (idiomatic)    | 2.015s  | 1.58x        | What a good developer would write   |
```

**The story:**
- Koru is **within 1% of hand-optimized Zig** - essentially tied
- Koru is **4% faster than Rust**
- Koru is **13% faster than optimized C**
- Koru is **58% faster than idiomatic Zig**

## What Makes This Honest

All implementations use equivalent optimizations where applicable:

| Implementation | Compiler | Optimization Flags |
|----------------|----------|-------------------|
| Koru | Zig 0.15.1 | `-O ReleaseFast` + `@setFloatMode(.optimized)` |
| Zig (optimized) | Zig 0.15.1 | `-O ReleaseFast` + `@setFloatMode(.optimized)` + `dsq*sqrt(dsq)` + fixed `[5]Body` |
| Zig (idiomatic) | Zig 0.15.1 | `-O ReleaseFast` only (no fast-math, slices, naive algo) |
| Rust | rustc 1.90.0-nightly | `-C opt-level=3 -C target-cpu=native` |
| C | Apple Clang 17.0.0 | `-O3 -ffast-math -fomit-frame-pointer -march=native` |

### Zig (idiomatic) - The Fair Baseline

The idiomatic Zig is what a competent developer writes without performance tuning:
- Uses slices (`[]Body`) instead of fixed arrays (`*[5]Body`)
- Uses while loops with manual index management
- Uses naive `distance * distance * distance` instead of `dsq * sqrt(dsq)`
- No `@setFloatMode(.optimized)`

This represents "normal good code" - correct, readable, maintainable.

### Zig (optimized) - Expert-Level Tuning

The optimized Zig has every trick applied:
- `@setFloatMode(.optimized)` for aggressive FP optimization
- `dsq * sqrt(dsq)` instead of `distance³` (saves 2 muls per pair)
- Fixed `[5]Body` array for loop unrolling
- Range-based for loops for better codegen

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

## The Aliasing Story

### Why Idiomatic Code Is Slower

```zig
// BAD: LLVM can't prove bodies[i] and bodies[j] don't overlap
bodies[i].vx -= dx * bodies[j].mass * mag;
bodies[j].vx += dx * bodies[i].mass * mag;
```

### The Solution

```zig
// GOOD: Separate pointers = proven non-aliasing
inline fn updatePair(b1: *Body, b2: *Body) void {
    b1.vx -= dx * b2.mass * mag;
    b2.vx += dx * b1.mass * mag;
}
```

Rust's borrow checker gives "free" noalias hints via `split_first_mut()`. Zig developers must manually structure code. **Koru's kernel system does this automatically** because it knows the semantics.

## Running the Benchmark

```bash
cd tests/regression/900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT
./benchmark.sh 10 50000000
```

## Files

- `2101g_nbody_kernel_pairwise/` - Koru kernel:pairwise implementation
- `2101_nbody_optimized/reference/baseline.zig` - Hand-optimized Zig
- `2101_nbody/reference/baseline.zig` - Idiomatic Zig
- `2101_nbody_optimized/reference/baseline.rs` - Rust implementation
- `2101_nbody_optimized/reference/reference.c` - C implementation

## Key Takeaway

**Koru's kernel system automatically generates expert-level optimizations.** The 58% gap between idiomatic and optimized Zig shows how much performance is left on the table by "normal" code. Koru closes that gap without requiring manual tuning.
