# PDR: Kernel Scope Optimizer

**Status:** Draft  
**Author:** Lars + Claude  
**Date:** 2026-03-28

## Problem Statement

Koru's kernel construct (`kernel:init`, `kernel:pairwise`, `kernel:self`) generates correct code, but cannot compete with hand-optimized implementations on benchmarks like n-body.

The core issue: **we cannot hoist iteration outside kernel operations.**

Current output for an iterated n-body:
```zig
for (0..iterations) |_| {
    // CALL into flow that contains:
    for (0..N) |i| {
        for (i + 1..N) |j| {
            // pairwise body
        }
    }
    advance_positions(...);
}
```

What we need:
```zig
const ptr = bodies.ptr;
for (0..iterations) |_| {
    for (0..N) |i| {
        for (i + 1..N) |j| {
            // pairwise body - fused, no calls
        }
    }
    // advance - fused inline
}
```

The difference is **fusion** - all operations on kernel data should be analyzed together and emitted as a single optimized block.

## Design Principle

**`kernel:init` looks at its entire downstream tree and rewrites it to be perfect.**

When you write `| kernel k |>`, everything that follows - every continuation, every nested operation, every loop - belongs to the kernel. The kernel doesn't just emit its own code and hope for the best. It **inspects the entire downstream AST** and emits a single, optimal, fused block.

The kernel sees:
- What operations touch `k`
- What loops wrap those operations  
- What the data dependencies are
- How to fuse it all into the tightest possible code

This is NOT about changing what `pairwise` means - pairwise IS the nested i<j loop pattern. This is about the kernel **owning its downstream tree** and emitting the whole thing as one optimized unit.

## Scope Boundaries

The kernel scope ends when:
- `k` is passed to a non-kernel event (escapes)
- `k` goes out of scope (continuation ends)
- Control flow diverges in ways that can't be fused

Within the scope, operations like:
- `kernel:pairwise { ... }`
- `kernel:self { ... }`
- `for(0..N) |> each |> ...` where body only touches `k`
- Pure computations on `k` fields

...can all be analyzed together.

## What the Optimizer Needs to Do

### Phase 1: Scope Tracking
- Walk the AST from `kernel:init` 
- Track the binding (`k`) through all continuations
- Mark scope boundaries (where `k` escapes or ends)
- Collect all kernel operations within scope

### Phase 2: Dependency Analysis
- For each operation, identify:
  - Which fields of `k` are read
  - Which fields of `k` are written
  - Dependencies between operations
- Build a dependency graph

### Phase 3: Fusion Decisions
- Identify fusable operation sequences
- Detect outer loops that can be hoisted
- Determine optimal loop ordering

### Phase 4: Code Generation
- Emit fused loop structure
- Inline all operations
- Apply layout transformations if beneficial

## Example: N-Body Fusion

Input:
```koru
~std.kernel:init(Body) { ... }
| kernel k |>
    for(0..iterations)
    | each _ |>
        std.kernel:pairwise { 
            // compute forces, update velocities
        }
        |> advance_positions(k)
```

Analysis:
- `k` bound at init
- `for(0..iterations)` is outer loop - HOIST CANDIDATE
- `pairwise` touches `k.vx`, `k.vy`, `k.x`, `k.y`, `k.mass`
- `advance_positions` touches `k.x`, `k.y`, `k.vx`, `k.vy`
- No escape - entire scope is kernel-controlled

Output:
```zig
const ptr = data[0..].ptr;
const N = data.len;
for (0..iterations) |_| {
    // pairwise - inlined
    for (0..N) |i| {
        for (i + 1..N) |j| {
            // force computation
        }
    }
    // advance - inlined
    for (0..N) |i| {
        ptr[i].x += ptr[i].vx * dt;
        ptr[i].y += ptr[i].vy * dt;
    }
}
```

## Non-Goals (For Now)

- GPU code generation (future backend)
- Automatic SoA transformation (needs access pattern analysis first)
- Parallelization (needs dependency analysis first)
- Tiling/blocking (optimization on top of fusion)

## Starting Point

The kernel transform is in `koru_std/kernel.kz`. The pairwise transform already:
- Finds the kernel binding name
- Transforms the body
- Emits the nested loop

The optimizer would be a **new pass** that runs after transforms but before final emission. It would:
1. Find all `kernel:init` flows
2. Analyze their downstream scope
3. Rewrite the AST to fuse operations
4. Let normal emission handle the fused result

## Success Criteria

The n-body benchmark (`tests/regression/900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT/nbody/`) should produce code that matches hand-written Zig performance within 5%.

## Open Questions

1. Where does this pass live? New file in `src/`? In `koru_std/optimizations/`?
2. How do we represent "fused kernel scope" in the AST?
3. Should this be a transform that rewrites AST, or a backend pass that emits differently?
4. How do we handle `k` being passed to user events that happen to be pure?

## References

- `koru_std/kernel.kz` - current kernel transforms
- `tests/regression/300_ADVANCED_FEATURES/390_KERNEL/` - kernel tests
- `tests/regression/900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT/nbody/` - benchmark
