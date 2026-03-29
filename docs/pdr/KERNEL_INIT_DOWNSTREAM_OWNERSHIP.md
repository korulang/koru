# PDR: Kernel Init Downstream Ownership

**Status:** Draft  
**Author:** Lars + Claude  
**Date:** 2026-03-28

## Problem Statement

We want `kernel:init` to produce optimal fused code for its entire downstream region. The current architecture has fundamental limitations:

1. **Transforms are peers**: Each transform (`pairwise`, `self`, `for`) handles its own invocation independently. There's no concept of one transform owning another's output.

2. **Transform ordering**: The compiler runs transforms depth-first. By the time `init` runs, `pairwise` has already transformed itself, adding `@scope` annotations that create barriers `init` can't see through.

3. **Scope boundaries**: The `@scope` annotation marks loop boundaries. When `for` or `pairwise` add `@scope`, the kernel loses visibility into that region.

The result: kernel operations emit locally-optimal code, but the *composition* of operations can't be fused.

## Key Insight

Kernel init is not a normal transform. It's a **language construct** that needs to:

1. Insert itself aggressively into the AST
2. Claim ownership of its downstream region
3. Rewrite that region into AST nodes the normal emitter can handle

Init doesn't emit Zig directly. It produces AST that *describes* the fused structure. The emitter then generates code from that AST using normal machinery.

The "thinking" (fusion analysis, loop hoisting) happens in init. The code generation uses existing compiler infrastructure.

## What Init Needs To See

When init looks at its `| kernel k |>` continuation, it needs to see the **raw, untransformed** subtree:

```
| kernel k |>
    for(0..iterations)
    | each _ |>
        std.kernel:pairwise { ... }
        |> advance_positions(k)
```

Not the already-transformed version with `@scope` barriers and inline code.

## Proposed Architecture

### 1. Kernel ops become `[norun]` declarations

`pairwise` and `self` stop being `[transform]` events. They become `[norun]` metadata - declarations that sit in the AST waiting for init to consume them.

```koru
~[comptime|norun]pub event pairwise {
    expr: ?Expression,
    source: Source
}
```

### 2. Init runs in an early phase

Before `evaluate_comptime` runs normal transforms, there's a phase where kernel regions are processed. Init finds its downstream subtree while it's still raw AST.

This could be:
- A new pass in the compiler pipeline (before `evaluate_comptime`)
- A special annotation like `[comptime|transform|early]`
- Init detecting and handling this in its transform phase

### 3. Init rewrites AST, doesn't emit Zig

Init's job is AST-to-AST transformation. It produces nodes the emitter understands:

```
kernel_fused_region {
    binding: "k",
    data_type: Body,
    layout: AOS,  // or SOA
    operations: [
        { type: pairwise, body: "...", deps: [...] },
        { type: self, body: "...", deps: [...] },
    ],
    outer_iteration: { range: "0..iterations", ... },
    downstream: [ advance_positions invocation, ... ]
}
```

The emitter sees `kernel_fused_region` and emits the fused loops.

### 4. The emitter handles the new node type

A new case in the emitter:

```zig
.kernel_fused_region => |kr| {
    // Emit ptr hoisting
    // Emit outer loop if present
    // Emit fused pairwise/self loops
    // Emit downstream operations inline
}
```

## What This Enables

### Fusion

Init sees pairwise followed by self, wrapped in a for. It emits:

```zig
const ptr = data.ptr;
for (0..iterations) |_| {
    // pairwise
    for (0..N) |i| {
        for (i+1..N) |j| { ... }
    }
    // self (advance)
    for (0..N) |i| { ... }
}
```

One fused block. Pointer hoisted. No call overhead.

### Layout control

Init knows the kernel shape and can decide AOS vs SOA:

```koru
~std.kernel:shape(Body) [layout: SOA] { x: f64, y: f64, mass: f64 }
```

The emitter respects this when generating field access.

### Future: dependency analysis

Init can analyze which fields each operation reads/writes. This enables:
- Reordering operations for cache efficiency
- Detecting parallelism opportunities
- GPU kernel generation

## Open Questions

### 1. How does init run before other transforms?

Options:
- New compiler pass in `compiler.kz` pipeline
- Special annotation that the transform runner respects
- Init detects raw kernel ops and handles them, while transformed ops go through normal flow

### 2. What AST node type for fused regions?

Need to add `kernel_fused_region` to `ast.Node`. What fields does it need?

### 3. How do we handle non-kernel ops in the subtree?

If there's a user event like `advance_positions(k)` in the kernel scope:
- Include it in the fused region (inline if pure)?
- Mark it as a "scope boundary" where fusion stops?
- Require it to be a kernel-native operation?

### 4. What about nested kernels?

Can you have a kernel inside a kernel? Probably not, but we should define this.

### 5. Error messages

When fusion fails (e.g., unsupported construct in kernel scope), we need clear errors explaining what went wrong and how to fix it.

## Implementation Phases

### Phase 1: Make ops `[norun]`

Convert `pairwise` and `self` to `[norun]` declarations. They stop transforming themselves.

**Risk**: This breaks all existing kernel code until Phase 2 is done.

### Phase 2: Init claims subtree

Modify init to walk its downstream continuation, find the `[norun]` kernel ops, and emit inline code for them.

At this phase, init emits Zig directly (like current pairwise does). Not yet AST nodes.

**Milestone**: Existing kernel tests pass again.

### Phase 3: Add fused region AST node

Define `kernel_fused_region` in ast.zig. Modify init to produce this node instead of inline code. Add emitter support.

**Milestone**: Same output, cleaner architecture.

### Phase 4: Fusion analysis

Init analyzes operation sequence and outer loops. Produces fused regions that the emitter turns into optimal code.

**Milestone**: N-body benchmark matches hand-written Zig.

### Phase 5: Layout control

Add `[layout: SOA]` annotation to shapes. Init and emitter respect it.

**Milestone**: Can switch between AOS and SOA with an annotation.

## Relationship to Other PDRs

- **KERNEL_LEXICAL_SCOPE_CLAUSE.md**: Defines what's allowed in kernel scope. This PDR is about *how* we enforce and leverage that ownership.

- **KERNEL_SCOPE_OPTIMIZER.md**: High-level vision for fusion. This PDR is the implementation strategy.

## Success Criteria

1. Kernel ops work without being `[transform]` events
2. Init successfully claims and processes its downstream subtree
3. Emitted code is fused (no call boundaries between kernel ops)
4. N-body performance matches or exceeds hand-written Zig
5. Architecture supports future layout control and GPU targeting

## Notes for Codex

This is complex. The core challenge is that we need init to see raw AST before transforms run, but we want to use normal compiler infrastructure for code generation.

The key insight: init is an AST-to-AST rewriter. It doesn't bypass the compiler - it produces AST that the compiler handles normally. The complexity is in init's analysis, not in special-casing the emitter.

Start with Phase 2: get init to handle pairwise/self directly. Once that works, we can introduce the formal AST node.
