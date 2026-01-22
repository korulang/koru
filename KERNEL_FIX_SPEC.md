# Kernel Transform Fix Specification

## Overview

The `$std/kernel` module provides high-performance data-parallel computation primitives. It's partially implemented but the continuation handling is broken.

## What Kernel Does

Kernel lets you describe **relationships between data elements**, not iteration patterns:

```koru
// Declare shape (metadata only)
~std.kernel:shape(Body) { x: f64, y: f64, mass: f64 }

// Initialize kernel data
~std.kernel:init(Body) {
    { x: 0.0, y: 0.0, mass: 1.0 },
    { x: 1.0, y: 0.0, mass: 2.0 },
}
| kernel k |> std.kernel:pairwise { k.mass += k.other.mass }
    | done |> print_results()
```

The compiler transforms this DSL into optimal nested loops.

## Current State

### What Works
- `kernel:shape` - `[norun]` event, just declares metadata in AST
- `kernel:init` - `[transform]` event, generates struct definition + variable
- Generated Zig code compiles

### What's Broken
**Continuation handling in `kernel:init`**

When user writes:
```koru
~std.kernel:init(Body) { ... }
| kernel k |> do_something(k)
```

The transform creates a `nop` event with NO branches, but keeps the original continuations. The continuation `| kernel k |>` expects a `kernel` branch that doesn't exist.

Error: `ERROR: Continuation references unknown branch 'kernel'`

## The Problem in Detail

### Current Transform Logic (kernel.kz lines ~260-330)

```zig
// Create no-op invocation for the head of the flow (LOCAL nop)
const nop_inv = ast.Invocation{
    .path = ast.DottedPath{
        .module_qualifier = null,
        .segments = &[_][]const u8{"nop"},
    },
    .args = &[_]ast.Arg{},
};

// Clone continuations (PROBLEM: these expect 'kernel' branch!)
var new_continuations = allocator.alloc(ast.Continuation, flow.continuations.len);
for (flow.continuations, 0..) |cont, i| {
    new_continuations[i] = cont;
}

// Create new flow with nop event
const new_flow = ast.Flow{
    .invocation = nop_inv,
    .continuations = new_continuations,  // <-- THESE EXPECT 'kernel' BRANCH
    .preamble_code = full_preamble,      // <-- struct + var code goes here
    // ...
};

// Also creates nop event declaration with NO BRANCHES
const local_nop_item = ast.Item{
    .event_decl = ast.EventDecl{
        .branches = &[_]ast.Branch{},  // <-- NO KERNEL BRANCH!
        // ...
    }
};
```

### The Mismatch

1. User continuation: `| kernel k |>` expects branch named `kernel`
2. Generated `nop` event: has zero branches
3. Shape checker: "continuation references unknown branch 'kernel'" → ERROR

## The Fix

### Option A: Add `kernel` Branch to `nop` Event

Make the generated `nop` event have a `kernel` branch:

```zig
// Generate nop event WITH a kernel branch
const kernel_branch = ast.Branch{
    .name = "kernel",
    .payload = ast.Shape{
        .fields = // ... fields from the generated struct
    },
};

const local_nop_item = ast.Item{
    .event_decl = ast.EventDecl{
        .branches = &[_]ast.Branch{kernel_branch},
        // ...
    }
};

// Generate nop proc that returns the kernel data
const local_nop_proc = ast.Item{
    .proc_impl = ast.ProcImpl{
        // return .{ .kernel = kernel_k };  (the generated variable)
    }
};
```

### Option B: Flatten Continuations (Preferred)

Instead of keeping continuations, emit inline code that:
1. Generates the struct/variable
2. Binds `k` to the variable
3. Emits the continuation's content directly

```zig
// Instead of creating a new flow with nop + continuations,
// emit inline code that does everything:

const code = std.fmt.allocPrint(allocator,
    \\const {type_name} = struct {{ {fields} }};
    \\var kernel_{binding} = [_]{type_name}{{ {init_values} }};
    \\// Now emit the continuation's content with k = kernel_{binding}
    \\{continuation_code}
, .{...});

// Replace flow entirely with inline code node
const new_item = ast.Item{
    .flow = ast.Flow{
        .inline_body = code,  // Everything in one inline block
        .continuations = &[_]ast.Continuation{},  // No continuations needed
    }
};
```

## Files to Modify

1. **`koru_std/kernel.kz`** - The transform implementation
   - `~proc init` (lines ~90-330) - Fix continuation handling
   - Consider adding `~proc nop` if using Option A

2. **Tests to verify:**
   - `tests/regression/300_ADVANCED_FEATURES/390_KERNEL/390_001_shape_basic/` - Basic init (works)
   - `tests/regression/300_ADVANCED_FEATURES/390_KERNEL/390_003_pairwise_basic/` - Chained (broken)

## Test Cases

### Test 1: Basic Init with Continuation
```koru
~std.kernel:shape(Body) { x: f64, mass: f64 }

~std.kernel:init(Body) { x: 1.0, mass: 2.0 }
| kernel k |> print_mass(k)

~event print_mass { k: Body }
~proc print_mass {
    std.debug.print("mass={d}\n", .{k.mass});
}
```
Expected: Prints `mass=2`

### Test 2: Pairwise Chaining
```koru
~std.kernel:shape(Body) { mass: f64 }

~std.kernel:init(Body) {
    { mass: 1.0 },
    { mass: 2.0 },
    { mass: 3.0 },
}
| kernel k |> std.kernel:pairwise { k.mass += k.other.mass }
    | done |> print_masses()
```
Expected: Pairwise adds masses, prints results

## Context

- Kernel is foundational for ECT/BLOOM (game engine ECS replacement)
- Also enables GPU compute, ML workloads, scientific computing
- The transform architecture is correct, just continuation handling is incomplete
- This is ~50-100 lines of fix in kernel.kz

## Commands

```bash
# Run kernel tests
./run_regression.sh 390

# Run specific test
./run_regression.sh 390_001  # basic init (works)
./run_regression.sh 390_003  # pairwise (broken)

# Check generated code
cat tests/regression/300_ADVANCED_FEATURES/390_KERNEL/390_001_shape_basic/output_emitted.zig | head -50
```

---

## Codex Analysis (2025-01-22)

Codex reviewed this spec and raised important architectural concerns:

### Codex's Observations

1. **The immediate bug is real**: `kernel:init` swaps the head invocation to a local `nop` with zero branches, while keeping continuations that expect `| kernel k |>`. This trips branch validation.

2. **Second semantic hole**: Even if we fix the branch table, `preamble_code` causes the emitter to skip the invocation entirely and emit continuation bodies directly. There's no switch/capture to bind `k`, so `| kernel k |> print_mass(k)` would still be undefined at runtime.

3. **Option B critique**: Flattening to `inline_body` would break `std.kernel:pairwise` and other downstream transforms, because it removes the AST invocations they need to find. Not viable if kernel transforms are meant to compose.

4. **Option A is recommended**: Generate a real branch + proc, remove `preamble_code` usage, let the normal invocation/switch path emit the binding. This keeps AST intact for later transforms.

### Codex's Gotchas

- **Name collisions**: The local event path `"nop"` is global. Multiple `kernel:init` calls will duplicate the same event/proc name. Need unique symbols like `kernel_init_<hash>`.

- **Payload shape**: Need to decide whether branch payload is struct value, slice, or pointer. Affects mutability and how `pairwise` rewrites.

- **Scope/lifetime**: If the proc returns a slice/pointer to a local var, that storage must outlive continuation usage. May need arena allocation or module-scope variables.

### Codex's Questions

> 1. Should `kernel k` be a slice, pointer, or value?
> 2. Should `kernel:init` be usable with arbitrary user events like `print_mass(k)`, or only with kernel transforms?

---

## Design Answers

### Answer 1: Kernel Handle = View into Arena

**`kernel k` should be a VIEW handle, not the data itself.**

```
┌─────────────────────────────────────────────────┐
│  KERNEL ARENA (preallocated, max size)          │
│  ┌─────────┬─────────┬─────────┬───────────┐   │
│  │ Body[0] │ Body[1] │ Body[2] │ ... free  │   │
│  └─────────┴─────────┴─────────┴───────────┘   │
└─────────────────────────────────────────────────┘
        ↑                   ↑
    View k              View k2
   (ptr, len=3)       (ptr+1, len=2)
```

The `kernel` branch payload is a view struct:

```zig
const KernelView = struct {
    ptr: [*]T,
    len: usize,
    capacity: usize,
    layout: LayoutHint,  // AoS, SoA, etc. (future)
};
```

**Why views, not raw data?**

| Operation | Input View | Output View | Notes |
|-----------|------------|-------------|-------|
| `init` | (allocates) | full view | Creates arena, returns view of all elements |
| `pairwise` | view | same view (mutated) | In-place mutation, same ptr/len |
| `map` | view | same or new view | Depends on transform |
| `filter` | view | smaller view | Same ptr, smaller len |
| `reduce` | view | scalar or new type | Different output entirely |
| `cross` | view, view | larger view | Product, may need arena expansion |

Views enable:
- Operations that shrink/grow without reallocation
- Multiple views into same underlying data
- Future: GPU memory mapping (view points to device memory)

### Answer 2: Arbitrary User Events = YES

**`kernel:init` MUST work with arbitrary user events.** The whole point is `k` is a first-class binding:

```koru
~std.kernel:init(Body) { ... }
| kernel k |> print_mass(k)                    // User event - MUST work
| kernel k |> std.kernel:pairwise { ... }      // Kernel transform - works
| kernel k |> my_custom_processor(data: k)     // User event - MUST work
```

If kernel only works with kernel transforms, the abstraction is leaky and useless for real programs.

---

## Bigger Vision: Analysis-Driven Layout

The shape of kernel data should be determined by **analyzing the entire continuation subtree** at compile time.

### The Flow Captures Everything

```koru
~std.kernel:init(Body) { ... }
| kernel k |>
    std.kernel:pairwise { k.mass += k.other.mass }  // Access pattern: random pairs
    | kernel k2 |>
        std.kernel:map { k2.x *= 2.0 }              // Access pattern: uniform
        | kernel k3 |> ...
```

The compiler can see:
- `pairwise` accesses `.mass` on random pairs → **AoS better** (cache locality)
- `map` accesses `.x` uniformly across all → **SoA better** (SIMD)
- **Conflict!** Compiler decides based on weights, or inserts layout transformation

### Compile-Time Analysis Pipeline

```
Parser → AST with kernel flows
           ↓
Analysis → Walk subtree, collect:
           - All field accesses per operation
           - Access patterns (uniform, pairwise, random, reduction)
           - Operation sequence and dependencies
           - Max element count at each stage
           ↓
Layout Decision → AoS, SoA, hybrid, tiled, blocked
           ↓
Codegen → Emit optimal representation for target
```

This is essentially **Halide for arbitrary data types**.

### GPU Offloading Potential

If views abstract the memory location:

```zig
const KernelView = struct {
    ptr: [*]T,           // Could be CPU or GPU memory
    len: usize,
    device: Device,      // .cpu, .cuda, .metal, .vulkan
    layout: Layout,
};
```

Then the SAME Koru code:

```koru
~std.kernel:init(Body) { ... }
| kernel k |> std.kernel:pairwise { k.mass += k.other.mass }
```

Could emit:
- **CPU**: Nested loops with SIMD intrinsics
- **CUDA**: Kernel launch with thread blocks
- **Metal**: Compute shader dispatch
- **Vulkan**: Compute pipeline

The user code doesn't change. The compiler decides based on:
- Target platform
- Data size (GPU overhead not worth it for small N)
- Operation characteristics

---

## Implications for the Fix

Given this vision, the immediate fix should:

1. **Use Option A** (real event + proc) - keeps AST intact for analysis
2. **Generate unique event names** - `kernel_init_{hash}` not `nop`
3. **Branch payload = view struct** - not raw slice, even if view is simple initially
4. **Arena allocation at flow scope** - not inside proc, to ensure lifetime
5. **Keep AST structure clean** - future analysis pass needs to walk it

### Minimal Fix vs Full Vision

**Minimal fix (do this now):**
- Fix branch/continuation mismatch
- Generate proper event + proc
- Use slice for now (upgrade to view later)
- Unique names to avoid collision

**Full vision (future):**
- Analysis pass for layout decisions
- View struct with metadata
- Backend selection (CPU/GPU)
- Layout transformations between operations

The minimal fix should NOT preclude the full vision. Don't hardcode assumptions that break later.

---

## What Exists Elsewhere?

To our knowledge, nothing quite like this exists:

- **Halide**: Image processing DSL with scheduling, but domain-specific
- **Futhark**: Functional GPU language, but separate from host language
- **Julia**: Great for numeric, but layout decisions are manual
- **Chapel**: Parallel language, but not embedded DSL with compile-time transforms
- **Kokkos/RAJA**: C++ abstractions, but no compile-time analysis

Koru's kernel system would be:
- **Embedded DSL** in a general-purpose language
- **Compile-time analysis** of data access patterns
- **Automatic layout decisions** (AoS/SoA/hybrid)
- **Backend agnostic** (CPU/GPU from same source)
- **Composable transforms** via continuation chains

If this works, it's genuinely novel.
