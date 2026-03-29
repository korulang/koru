# PDR: Kernel Lexical Scope Clause

**Status:** Draft  
**Author:** Codex  
**Date:** 2026-03-28

## Purpose

Define the first hard semantic clause for Koru's high-performance kernel model:

> A kernel is a **lexically closed computation region**. The kernel handle does not escape its subtree.

This PRD is intentionally narrow. It does **not** implement the full optimizer. It gives Claude a small, honest target:

1. codify the clause,
2. reject unsupported cases early,
3. preserve room for the later fused-region optimizer.

## Why This Clause Matters

The high-performance story only works if the compiler can treat a kernel subtree as a closed world.

If `kernel:init` is allowed to hand `k` to arbitrary user events, then:

- aliasing becomes a guess again,
- region ownership becomes blurry,
- subtree planning becomes unreliable,
- "optimal lowering" becomes marketing instead of semantics.

The kernel contract should be:

- `kernel:init` introduces a kernel region,
- the region is bounded by the `| kernel k |>` continuation subtree,
- `k` is a compiler capability, not a normal value,
- `k` cannot escape to arbitrary user code.

This is stricter than general Koru resource/capability flows, and that is correct. A computational kernel is not a resource handle API.

## Clause

### Kernel Scope Rule

When a flow contains:

```koru
~std.kernel:init(T) { ... }
| kernel k |> ...
```

the binding `k` is only valid inside the lexical continuation subtree rooted at that `kernel` branch.

### No Escape Rule

The kernel binding `k` must not be:

- passed to a non-kernel event,
- stored in a captured structure intended to outlive the subtree,
- returned through a non-kernel branch,
- forwarded into unknown code,
- used in a way that prevents `kernel:init` from owning the subtree.

### Allowed Within Kernel Scope

Initially, allow only a small set of operations to remain inside kernel scope:

- `std.kernel:pairwise { ... }`
- `std.kernel:self { ... }`
- a tightly controlled outer `for` shape if already supported by the transform architecture
- pure inline computations on values derived from kernel fields, if they do not leak `k`

Everything else should either:

- terminate kernel scope, or
- fail compilation with a direct error.

For the first implementation, **prefer fail-fast over implicit scope termination**.

## Non-Goals

This clause is **not** the full kernel optimizer.

Do not try to solve all of the following in this PR:

- loop fusion across arbitrary control flow,
- AoS/SoA automatic layout selection,
- GPU lowering,
- user-event purity inference,
- general escape analysis,
- backend-specific performance tuning.

The point of this PR is to make the semantics honest before making them powerful.

## Implementation Strategy

### Core Idea

Make `kernel:init` smart enough to validate ownership of its lexical subtree before lowering.

Do **not** let downstream kernel ops force the architecture by eagerly lowering themselves first.

For now:

1. `kernel:init` finds the `| kernel k |>` continuation subtree.
2. It walks that subtree recursively.
3. It classifies each node as:
   - allowed kernel op,
   - allowed structural node,
   - forbidden escape / unsupported node.
4. If forbidden, compilation fails with a kernel-specific error.
5. If allowed, normal kernel lowering continues.

This gives us the clause now, while preserving the path to a later "collect subtree → build plan → emit one fused region" implementation.

### Minimal Acceptance Rule

For the first pass, a subtree is valid only if every invocation reachable from `| kernel k |>` is one of:

- `std.kernel:pairwise`
- `std.kernel:self`
- known structural forms that do not leak `k`

Any invocation outside this set fails if `k` is still in scope.

This is intentionally conservative.

## Concrete Compiler Behavior

### Valid

```koru
~std.kernel:init(Body) { ... }
| kernel k |>
    std.kernel:pairwise { k.mass += k.other.mass }
    |> std.kernel:self { k.mass *= 2.0 }
```

### Invalid: User Event Escape

```koru
~std.kernel:init(Body) { ... }
| kernel k |> print_mass(value: k.ptr[0].mass)
```

Reason:

- even though only a scalar is passed here, this PR treats arbitrary user-event participation as outside the kernel contract.
- this is the correct conservative failure mode for the first clause.

If later we want "scalar extraction ends kernel scope", that can be added explicitly.

### Invalid: Passing Kernel Handle

```koru
~std.kernel:init(Body) { ... }
| kernel k |> consume_kernel(data: k)
```

This must fail.

### Invalid: Unknown Nested Control

```koru
~std.kernel:init(Body) { ... }
| kernel k |>
    maybe_do_something(k)
```

This must fail until the operation is modeled as part of kernel semantics.

## Error Message

Use a direct, semantic error. Example:

```text
ERROR: kernel scope escape
kernel binding 'k' may only be used inside supported std.kernel operations
found unsupported invocation 'print_mass' inside kernel scope
```

Keep the message concrete. Do not mention implementation internals.

## Suggested Files

- [`koru_std/kernel.kz`](/Users/larsde/src/koru/koru_std/kernel.kz)
  Add subtree validation in `kernel:init` before lowering.

- [`tests/regression/300_ADVANCED_FEATURES/390_KERNEL/`](/Users/larsde/src/koru/tests/regression/300_ADVANCED_FEATURES/390_KERNEL/)
  Add one or more regression cases proving unsupported kernel escapes fail.

Likely impacts:

- existing permissive kernel tests may need to be split into:
  - allowed kernel-internal cases,
  - rejected escape cases.

## Testing Plan

### Add Failing/Negative Tests

1. Kernel handle passed to user event should fail.
2. Arbitrary invocation inside kernel scope should fail.
3. Existing kernel-only patterns should still pass.

### Preserve Existing Positive Cases

- basic `kernel:init`
- `kernel:pairwise`
- `kernel:self`

## Design Notes For Claude

Keep the implementation narrow.

Do not attempt to solve "optimal codegen" in the same PR.

The correct move is:

- make the contract stricter,
- fail fast,
- unblock the later optimizer by ensuring kernel scope is truly owned.

That later optimizer can then safely assume:

- no escape,
- no arbitrary aliasing,
- no unknown event boundaries inside the region,
- subtree planning is sound.

## Success Criteria

This PR is successful if:

- the kernel lexical-scope clause is explicit in code and tests,
- unsupported uses fail with a kernel-specific error,
- current allowed kernel-only flows still work,
- the change makes the future fused-region optimizer easier, not harder.
