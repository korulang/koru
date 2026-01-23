# N-Body Benchmark Status

**Last benchmarked:** 2026-01-23
**Test:** 50M iterations, 5 bodies (solar system)
**Machine:** Apple Silicon (ARM64)

## BREAKTHROUGH: We Beat Rust!

| Rank | Implementation | Time | vs Rust |
|------|---------------|------|---------|
| 1 | **Koru kernel:pairwise** | **1.33s** | **0.98x** |
| 2 | **Zig noalias** | **1.34s** | **0.99x** |
| 3 | **Rust** | **1.36s** | **1.00x** |
| 4 | Koru arrayed capture | 1.43s | 1.05x |

## The Solution: Pointer Aliasing + Static Backing

**Aliasing was the first gap; static backing + constant bounds closed the rest.**

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

**This is HUGE.** The kernel pairwise transform knows by definition that `k` and `k.other` are different bodies. We now generate the optimized pattern automatically, and emit static backing when init size is known (implemented 2026-01-23):

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
| **Static kernel backing + const N** | **~6% gain** | Avoid heap + enable fixed bounds |

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

## Koru Implementations

### kernel:pairwise (now faster than Rust)

**`2101g_nbody_kernel_pairwise`** - Full benchmark using kernel DSL:
```koru
~parse_args()
| n iterations |>
    std.kernel:init(Body) { ... }
    | kernel k |>
        for(0..iterations)
            | each _ |>
                std.kernel:pairwise { k.vx -= dx * k.other.mass * mag; ... }
                |> advance_positions(bodies: k.ptr[0..k.len])
```

Generates the noalias pointer pattern. With static backing and constant bounds, it now beats Rust (~1.33s on this machine).

### Manual capture (6% behind Rust)

**`2101f_nbody_arrayed_capture`** - Uses array indexing without kernel DSL:
```koru
captured { dv[i][0]: acc.dv[i][0] - f.fx*f.mj }
```

This approach doesn't benefit from kernel semantics - LLVM can't prove non-aliasing.

### Recommendation

**Use `kernel:pairwise` for pairwise computations.** The DSL generates noalias code automatically.

## Running Benchmarks

```bash
cd tests/regression/900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT

# Build the Koru kernel:pairwise benchmark first
cd 2101g_nbody_kernel_pairwise
zig build-exe output_emitted.zig -O ReleaseFast --name a.out
cd ..

# Run benchmarks
hyperfine --warmup 3 --runs 10 \
    "./2101_nbody/reference/nbody-rust 50000000" \
    "./nbody-noalias 50000000" \
    "./2101g_nbody_kernel_pairwise/a.out 50000000" \
    "./2101f_nbody_arrayed_capture/a.out 50000000"
```

## Key Takeaway

**Aliasing analysis + static backing were the performance gap.**

Rust's borrow checker gives it "free" noalias hints. Zig (and C) developers must manually structure code to help LLVM.

**Koru's kernel system can do this automatically** because it KNOWS the semantics:
- `pairwise` = two different elements = noalias guaranteed
- Generate pointer-based inline functions
- Use static backing + constant bounds when init size is known
- Match or beat Rust performance with cleaner syntax

This is the value of domain-specific languages.
