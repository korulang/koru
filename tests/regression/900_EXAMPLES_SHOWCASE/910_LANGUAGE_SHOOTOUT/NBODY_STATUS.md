# N-Body Benchmark Status

**Last benchmarked:** 2026-01-23
**Test:** 50M iterations, 5 bodies (solar system)
**Machine:** Apple Silicon (ARM64)

## BREAKTHROUGH: We Match Rust!

| Rank | Implementation | Time | vs Rust |
|------|---------------|------|---------|
| 1 | **Rust** | **1.36s** | **1.00x** |
| 2 | **Zig noalias** | **1.37s** | **1.00x** ← TIED! |
| 3 | Zig SIMD | 1.41s | 1.04x |
| 4 | Zig forloop | 1.42s | 1.04x |
| 5 | Koru arrayed capture | 1.43s | 1.05x |

## The Solution: Pointer Aliasing

**The entire 4% gap was aliasing analysis.**

### The Problem
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

### Why Rust Won Before
Rust's `split_first_mut()` pattern:
```rust
let (body1, rest) = bodies[i..].split_first_mut().unwrap();
for body2 in rest { ... }
```
The borrow checker PROVES to LLVM that `body1` and `body2` are disjoint memory.

## Implications for Koru Kernel System

**This is HUGE.** The kernel pairwise transform knows by definition that `k` and `k.other` are different bodies. We can generate the optimized pattern automatically:

```koru
// User writes (natural, clean):
~std.kernel:pairwise { k.vx += f; k.other.vx -= f }
```

```zig
// Kernel generates (optimized, non-idiomatic):
inline fn __kernel_pair(k: *Body, other: *Body) void {
    k.vx += f;
    other.vx -= f;
}

for (0..N) |i| {
    for (i+1..N) |j| {
        __kernel_pair(&bodies[i], &bodies[j]);
    }
}
```

**The DSL advantage:**
- User writes declarative `k` / `k.other` syntax
- Compiler KNOWS pairwise semantics = non-aliasing
- Codegen emits OPTIMAL pointer-based pattern
- **Natural Koru code matches hand-optimized Zig/Rust**

## Optimization Experiments Summary

| Optimization | Result | Why |
|-------------|--------|-----|
| SoA layout | **Slower** | Cache locality worse for N=5 |
| Loop splitting | No change | Already optimized |
| Manual unrolling | **Slower** | Code bloat hurts icache |
| Comptime unrolling | No change | Compiler already unrolls |
| Explicit SIMD | 3% gain | Helps but not the bottleneck |
| Precomputed mass | Slower | Extra memory hurts |
| **Pointer noalias** | **4% gain** | **THIS WAS THE KEY** |

## Files

### Winner
- `nbody_noalias.zig` - **Matches Rust!** Uses separate `*Body` pointers

### Other experiments
- `nbody_handopt.zig` - SoA + manual unroll (slower)
- `nbody_handopt2.zig` - SoA only (slower)
- `nbody_split.zig` - Rust-style loop splitting (no change)
- `nbody_simd.zig` - Explicit SIMD vectors
- `nbody_simd2.zig` - SIMD + comptime unroll
- `nbody_simd3.zig` - Precomputed mass vectors (slower)

## Best Koru Implementation (Current)

**`2101f_nbody_arrayed_capture`** - 5% behind Rust, uses array indexing:
```koru
captured { dv[i][0]: acc.dv[i][0] - f.fx*f.mj }
```

**TODO:** Update kernel pairwise codegen to use pointer pattern for Rust-matching performance.

## Running Benchmarks

```bash
cd tests/regression/900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT
hyperfine --warmup 3 --runs 10 \
    "./2101_nbody/reference/nbody-rust 50000000" \
    "./nbody-noalias 50000000" \
    "./2101f_nbody_arrayed_capture/a.out 50000000"
```

## Key Takeaway

**Aliasing analysis was the entire performance gap.**

Rust's borrow checker gives it "free" noalias hints. Zig (and C) developers must manually structure code to help LLVM.

**Koru's kernel system can do this automatically** because it KNOWS the semantics:
- `pairwise` = two different elements = noalias guaranteed
- Generate pointer-based inline functions
- Match Rust performance with cleaner syntax

This is the value of domain-specific languages.
