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
