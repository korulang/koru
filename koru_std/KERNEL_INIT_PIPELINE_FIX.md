# Fix: Allow kernel:init in Pipeline Steps

## Goal

Enable `kernel:init` to be used as a step in a pipeline, not just as a top-level flow invocation.

**We need this to work:**
```koru
~parse_args()
| n iterations |>
    std.kernel:init(Body) { ... }
    | kernel k |>
        for(0..iterations)
            | each _ |>
                std.kernel:pairwise { ... }
                |> advance_positions(...)
```

**Currently only this works:**
```koru
~std.kernel:init(Body) { ... }
| kernel k |>
    std.kernel:pairwise { ... }
```

## Current Limitation

File: `koru_std/kernel.kz`, lines 150-156

```zig
// ========================================================================
// STEP 1: Verify we're the top-level invocation
// ========================================================================
if (invocation != &flow.invocation) {
    // This shouldn't happen for init, but handle gracefully
    @panic("kernel.init: expected to be top-level invocation");
}
```

The transform assumes `kernel:init` is the head invocation of a flow, so it can:
1. Find the `| kernel k |>` continuation from the flow's continuations
2. Replace the entire flow's head invocation with a generated local event

## What Needs to Change

When `kernel:init` is a step in a pipeline (not head invocation), the transform needs to:

1. **Find the continuation differently** - The `| kernel k |>` will be attached to the step, not the flow
2. **Generate code differently** - Instead of replacing the flow's head invocation, inject the kernel initialization inline in the pipeline

## Test Case

Already created: `tests/regression/300_ADVANCED_FEATURES/390_KERNEL/390_023_init_in_pipeline/`

```koru
~event get_count {}
| n u32

~proc get_count {
    return .{ .n = 3 };
}

~get_count()
| n count |>
    std.kernel:init(Body) {
        { mass: 1.0 },
        { mass: 2.0 },
        { mass: 3.0 },
    }
    | kernel k |>
        std.kernel:pairwise { k.mass += k.other.mass }
```

## Why This Matters

We need to build an nbody benchmark that:
1. Parses iteration count from command line args
2. Uses kernel:pairwise with noalias optimization
3. Loops N times with pairwise + position updates
4. Compares against Rust (target: match 1.36s on 50M iterations)

Without kernel:init in pipelines, we can't combine arg parsing with kernel operations in a clean flow.

## Reference

- Working top-level pattern: `tests/regression/300_ADVANCED_FEATURES/390_KERNEL/390_003_pairwise_basic/input.kz`
- Benchmark target: `tests/regression/900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT/2101g_nbody_kernel_pairwise/`
