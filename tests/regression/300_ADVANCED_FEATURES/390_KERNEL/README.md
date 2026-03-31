# Koru Kernel Manifesto

**Why kernels exist, what they guarantee, and why they are fast**

## 1. Kernels are not “functions”

A Koru kernel is **not** a general-purpose function and must not be treated as one.

A kernel is:

* A **restricted DSL** embedded in Koru
* Executed under **algorithm-owned control flow**
* Compiled under **strong semantic guarantees**
* Lowered into **straight-line, optimizer-friendly code**

The kernel body does *not* own control flow, memory layout, or scheduling.
Those are the responsibility of the kernel algorithm (`pairwise`, `map`, `reduce`, etc.).

This restriction is intentional and foundational.

---

## 2. Kernel code is GPU-expressible by design

All kernel bodies must be expressible as GPU kernels.

This implies:

* No pointer escape
* No hidden aliasing
* No arbitrary global mutation
* No recursion
* No unbounded dynamic allocation
* No calling unknown functions

If kernel code cannot be mapped to a GPU execution model, it does not belong in a kernel.

This constraint is a feature, not a limitation.

---

## 3. Kernels operate on *capabilities*, not pointers

Inside a kernel, symbols such as `k` and `k.other` are **capability views**, not raw pointers.

Each capability has:

* A **fixed access scope** (which elements, which fields)
* A **fixed permission** (read-only or write-only)
* A **fixed lifetime** (kernel invocation)

Example:

* `k` → may write fields of element `i`
* `k.other` → may read fields of element `j`
* `k.other` is *always* read-only by construction

Kernel code cannot widen, clone, or store these capabilities.

This is stronger than conventional alias analysis and stronger than typical language-level borrowing.

---

## 4. Kernel algorithms own control flow *(aspirational)*

Kernel algorithms (`pairwise`, `map`, `filter`, `reduce`, etc.) fully own:

* Loop structure
* Traversal order
* Parallelization strategy
* Scheduling
* Tiling
* Vectorization decisions

The kernel body is a **pure-ish expression over known symbols** evaluated within that flow.

As a result:

* The compiler never has to infer intent
* The optimizer never fights abstraction
* Hot paths are explicit by construction

---

## 5. Layout is a compiler decision, not a user promise *(aspirational)*

Kernel bodies make **no guarantees** about data layout.

The kernel system may choose:

* AoS (Array of Structs)
* SoA (Struct of Arrays)
* Hybrid layouts (hot fields SoA, cold fields AoS)
* Transient scratch layouts

Layout is selected based on:

* Which fields are accessed
* How they are accessed (streaming vs clustered)
* Which kernel algorithms are applied
* Cache and vectorization considerations

All layout choices are resolved at compile time and fully monomorphized.

No runtime layout branching is permitted in hot loops.

---

## 6. Writes are staged; reductions are promoted *(aspirational)*

Kernel semantics allow (and encourage) **reduction promotion**.

For example:

```koru
k.mass += k.other.mass
```

is *not* required to lower to a memory load/store per iteration.

Instead, the compiler may:

* Load `k.mass` once into a private accumulator
* Perform all inner-loop math in registers
* Commit the result with a single store

This eliminates loop-carried memory dependencies and enables:

* Vectorization
* Unrolling
* Reordering
* Parallel execution

This transformation is always legal under kernel rules.

---

## 7. Aliasing is solved by construction

Kernels do not rely on heroic alias analysis.

Instead:

* Read-only capabilities never write
* Write targets are partitioned by algorithm semantics
* Pointer escape is forbidden
* Stores are delayed and isolated

As a result, generated code can be shaped so that:

* Aliasing either provably does not matter
* Or is eliminated structurally before LLVM sees it

This is more reliable than relying on `noalias` metadata alone.

---

## 8. Zig is the IR, not the abstraction boundary

Koru kernels lower to **plain Zig**, but not *idiomatic* Zig.

They lower to:

* Monolithic loops
* Explicit indices
* Scalar temporaries
* Single commit points
* Fully inlined logic

The goal is to emit Zig that looks like:

> “What an expert would have written by hand for this exact kernel.”

Inlining is structural, not heuristic.

If a helper touches kernel memory, it does not exist as a function.

---

## 9. PGO guides; kernels decide *(aspirational)*

Profile-Guided Optimization (PGO) is used to:

* Identify hot kernels
* Select tiling factors
* Choose unroll and vector widths
* Guide layout decisions

PGO does **not** decide kernel structure.

Kernel semantics already expose:

* What is hot
* What is safe to reorder
* What is parallelizable

PGO refines decisions; it does not discover them.

---

## 10. Performance goals (explicit and honest)

Koru does not aim to “beat Rust everywhere.”

Instead:

* Koru kernels aim to **outperform general-purpose code** by exploiting semantic restrictions
* Koru aims to beat Go consistently on data-parallel workloads
* Koru aims to match or exceed Rust when Rust is written *idiomatically*, not heroically
* When Rust is hand-specialized to the same shape, parity is a success

Any benchmark where Koru wins should be explainable by:

> “The compiler knew more, earlier, and structured the code better.”

---

## 11. Kernels are a contract

Kernel performance is not an accident.

It is the result of a contract:

* The programmer gives up generality
* The compiler guarantees optimal structure

Breaking the contract invalidates the guarantees.

Honoring it unlocks:

* Predictable performance
* Scalable parallelism
* Hardware-efficient codegen
* Sanity

---

## 12. Philosophy

Kernels are how Koru says:

> “If you tell us what you’re doing, we will not make you fight the compiler.”

And that’s the whole point.

---

## Work Doc (Living)

### Implemented (see tests)

**Core shapes and init:**
- 390_001: `kernel:shape` + `kernel:init` emits a view-backed kernel handle
- 390_002: Array-mode init with multiple element blocks
- 390_023: `kernel:init` works as a pipeline step, not just top-level
- 390_021: Multi-line source blocks in kernel operations
- 390_010: Layout hint field exists (stubbed to "aos")
- `kernel:init` event declares `| kernel k |>` and `| computed c |>` branches
  (`computed` is optional, receives the final data after kernel ops complete)

**Kernel operations:**
- 390_003: `kernel:pairwise` — nested i<j loops, `k` and `k.other` access
- 390_040: `kernel:self` — single-loop per-element iteration
- 390_042: `kernel:pairwise` with both `k` and `k.other` writable (symmetric)
- 390_043: `kernel:pairwise` with `k.other` read-only (GPU-friendly form)

**Multi-op and computed:**
- 390_060: Multi-op kernel/computed split (TODO — requires fusion wiring)

**Scope validation:**
- 390_050: `for` rejected inside kernel scope
- 390_051: Branch constructors rejected inside kernel scope
- 390_052: User events inside kernel scope (aspirational, currently FAILING)
- 390_053: Stdlib events inside kernel scope (aspirational, currently FAILING)

**Benchmark:**
- 390_020: N-body gravitational sim using `kernel:pairwise`
- 910_LANGUAGE_SHOOTOUT/nbody: Full 5-body solar system benchmark
  - Kernel pairwise version: 1.271s (1.04x vs C on 50M iterations)

### The Multi-Step Fusion Problem

Today, each kernel operation is an independent transform that emits its own
code. When you chain operations on the same kernel data, each generates
separate pointer extraction and loop structure:

```koru
| kernel k |>
    std.kernel:pairwise { /* forces */ }
    |> std.kernel:self { k.x += k.vx * dt }
```

Current output (conceptual):
```zig
const __ptr0 = k.ptr;                    // pairwise extracts ptr
for (0..N) |i| {
    for (i + 1..N) |j| { /* forces */ }
}
const __ptr1 = k.ptr;                    // self extracts ptr AGAIN
for (0..N) |i| {
    __ptr1[i].x += __ptr1[i].vx * dt;
}
```

What we want:
```zig
const __ptr = k.ptr;                     // one extraction
for (0..N) |i| {
    for (i + 1..N) |j| { /* forces */ }
}
for (0..N) |i| {                         // fused, no re-extraction
    __ptr[i].x += __ptr[i].vx * dt;
}
```

The problem gets worse with an outer iteration loop. The shootout benchmark
writes:

```koru
| kernel k |>
    for(0..iterations)
    | each _ |>
        std.kernel:pairwise { ... }
        |> advance_positions(bodies: k.ptr[0..k.len])
```

Here `for(0..iterations)` lives outside the kernel scope. Each iteration
calls into pairwise (a separate transform) and then into `advance_positions`
(a user event). The compiler cannot see through these call boundaries to fuse
the loops or hoist pointer extraction.

**The gap is not expressivity — the current API correctly computes nbody.
The gap is wiring: init can see its subtree (via `claims_descendants`) but
cannot yet fuse kernel operations into a single code block and deliver the
result through the `computed` branch.**

### How Subtree Ownership Works

`kernel:init` is annotated `[comptime|transform|claims_descendants]`. The
transform runner (`src/transform_pass_runner.zig`) checks `claims_descendants`
transforms **before** walking children (depth-first). This means init sees
the raw, untransformed subtree — `kernel:pairwise` and `kernel:self` are
still AST invocations, not yet lowered to inline Zig code.

The ordering guarantee:

- **Without `claims_descendants`** (old): pairwise runs first (depth-first),
  replaces itself with inline code, then init sees already-lowered code.
  Order: pairwise → init.
- **With `claims_descendants`** (current): init runs before its children
  are walked. It sees the raw `kernel:pairwise` invocation. Order: init → pairwise.

Verified by `src/transform_pass_runner_test.zig:144`:
`outer_saw_raw_inner_invocation = true` when `claims_descendants = true`.

### The Kernel/Computed Split

`kernel:init` declares two branches:

```koru
~std.kernel:init(Body) { ... }
| kernel k |>
    std.kernel:pairwise { ... }    // closed region — only kernel ops
    |> std.kernel:self { ... }
| computed c |>
    std.io:print.blk { ... }       // normal code — runs after kernel region
```

- **`| kernel k |>`** — closed region. Only `kernel:pairwise` and `kernel:self`
  allowed. Init owns this subtree. This is where fusion happens.
- **`| computed c |>`** — post-processing. Normal code with access to the final
  data via `c`. This is how you exit the kernel scope and get back to regular
  programming. `computed` is optional — if omitted, init returns through `kernel`.

The `computed` branch is NOT optional in principle — it's the ONLY way to access
kernel results in normal code. Without it, data is trapped inside the kernel scope.
It's marked optional in the event declaration for backward compatibility, but
every kernel program that needs its results must use it.

### What init uses this for today

Subtree validation. Before any kernel op lowers itself, init walks `| kernel k |>`
and rejects unsupported constructs (`for`, `if`, branch constructors, user events).
See `validateKernelSubtree` in `koru_std/kernel.kz:161`.

### The Fusion Wiring Gap

When `computed` is present, init's proc returns through `.computed`. The emitted
code dispatches via `switch`:

```zig
switch (result_0) {
    .kernel => |k| {
        // pairwise + self inline code runs HERE
        for (0..N) |i| { for (i+1..N) |j| { ... } }
        for (0..N) |i| { ... }
    },
    .computed => |c| {
        // post-processing runs HERE
        print(c[0].mass, ...);
    },
}
```

The problem: if the proc returns `.computed`, the `.kernel` branch is skipped.
The kernel ops are collected (they're in the kernel branch), but they never execute.

**The fix is fusion:** init must lift kernel operations OUT of the `.kernel`
branch handler and INTO the flow function, inline, before the `.computed`
dispatch. Then init returns through `.computed` with already-computed data:

```zig
// FUSED: kernel ops run inline, then computed gets the result
const __ptr = kernel_init_data[0..].ptr;
for (0..N) |i| { for (i+1..N) |j| { /* pairwise */ } }
for (0..N) |i| { /* self */ }
// computed branch gets the post-kernel data
print(kernel_init_data[0..][0].mass, ...);
```

This is 390_060 (currently TODO).

### What Fusion Requires

The `claims_descendants` mechanism gives init the raw subtree. The kernel/computed
split gives init a clean exit path. What's missing is the wiring:

1. **Init walks the subtree** (already done for validation).
2. **Init collects kernel operations** during that walk:
   `{ type: pairwise, body: "..." }, { type: self, body: "..." }`.
3. **Init emits fused code inline in the flow function** — not inside the
   `.kernel` branch handler, but in the flow function itself, before the
   `.computed` dispatch. One `const ptr = k.ptr`, one set of loops per op.
4. **Init returns through `.computed`** with the already-mutated data.
   The `computed` branch receives post-kernel data and runs normal code.

### What Blocks Fusion Today

- **Init doesn't collect operations.** The subtree walk exists (for validation)
  but doesn't gather pairwise/self into a plan.

- **Kernel ops emit into the `.kernel` branch handler.** When init returns
  through `.computed`, the `.kernel` branch is never taken. The ops are
  generated but dead.

- **Init needs to move ops from the branch handler to the flow function.**
  This means init must intercept pairwise/self, prevent them from running as
  independent transforms, and emit their code directly into the flow.

### Next Milestones

1. **Init collects and consumes its subtree.** Extend the validation walk to
   collect pairwise/self operations. Init emits them as inline code in the
   flow function. Pairwise/self are prevented from running independently
   (either consumed from AST or marked as already-transformed).

2. **Wire computed branch.** Init returns through `.computed`. The inline
   kernel ops run first, then the `computed` branch receives post-kernel data.
   390_060 passes.

3. **Pointer hoisting.** Init emits one `const ptr = k.ptr` for the entire
   fused region instead of each op extracting its own.

4. **Lift `for` restriction for known shapes.** Allow `for(0..N) |> each`
   inside kernel scope when the body only contains kernel ops. This unblocks
   the iterated multi-step pattern.

5. **Outer-loop fusion.** When init sees `for |> each |> [kernel ops]`,
   it emits the `for` as the outer loop with kernel ops fused inside.

6. **Layout analysis.** AoS/SoA/hybrid decisions driven by access patterns
   visible in the fused region.

7. **Backend selection.** GPU lowering for kernel regions (strip `k.other`
   writes, emit per-element shader kernels).
