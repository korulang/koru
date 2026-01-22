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

## 4. Kernel algorithms own control flow

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

## 5. Layout is a compiler decision, not a user promise

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

## 6. Writes are staged; reductions are promoted

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

## 9. PGO guides; kernels decide

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

**Implemented (see tests):**
- 390_001_shape_basic: init emits a view-backed kernel handle
- 390_003_pairwise_basic: pairwise uses view access (`k.ptr[i]`, `k.len`)
- 390_005_user_event_binding: arbitrary user events can consume values derived from `k`
- 390_010_layout_metadata: layout hint exists (stubbed to "aos")

**Aspirational (future):**
- Layout analysis pass to compute real layout hints

**Next milestones:**
- Layout analysis pass (AoS/SoA/hybrid decisions)
- Escape-aware allocation (stack vs arena)
- Backend selection (CPU/GPU) driven by kernel metadata
