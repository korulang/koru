---
type: belief
id: frag-compile-memory-was-never-about-capacity
provenance: SIGKILL diagnosis on tests/benchmarks/003_ecs_reactive (2026-09-05) — malloc_history + GPA requested-bytes counters against a 10-line store program, cross-checked hello/mini/benchmark
ts: 2026-09-05
---

# Compile memory was never about capacity — and the ceiling is the compiler's contract, not the OS's

Prior belief (the handoff baton's, from this morning's session): monolithic
stores at 50k–100k capacity blow up `zig build` with static BSS arrays and
unrolled loop transforms. Measured against the tree this session, that was
wrong at every layer at once:

- The killed process is the metacircular BACKEND (Stage C), not `zig build`;
  the backend binary build was a cache hit. `zig build` never appears at the
  peak.
- Capacity is not the axis: a 10-line program at capacity 10 costs the same
  order as at capacity 100000. hello (3 lines, no store at all) cost 1.4 GB.
- The emitted Zig file is a red herring: 1.5 MB of text, no capacity-sized
  static arrays, and the process died before emitting the final program at all.

The real cost was the compiler allocating O(program × transformed sites)
through TWO allocator universes the compile arena could not see:

1. `flatItems` (koru_std/store.kz) flattened the whole program AST — including
   the stdlib import closure — per field, per leaf, per interceptor arm;
   ~30 call sites; every result retained on the compile arena, which frees
   nothing until exit.
2. `AutoDischargeInserter` (wired in koru_std/compiler.kz with a hardcoded
   `std.heap.page_allocator`) deep-cloned the ENTIRE program per checked flow
   via `ast_functional.replaceFlowRecursive`; per-allocation mmap, nothing
   freed, invisible to the compile arena's accounting. A 10-line program paid
   ~2.6 GB here alone.

Fixes (this commit): per-epoch memo on `flatItems` (keyed on the items slice
header — every structural write-back allocates a fresh array or boxes a new
Program, so minted declarations are never hidden behind a stale list);
O(change) write-backs in `ast_functional` (unchanged items shared by value —
safe because the runner re-derives site refs per walk and abandons the old
program, already shallow-copies site programs, and accepts in-place mutation
of the writable seed); pass allocators threaded to `ctx.allocator`; and the
budget: the generated backend wraps the compile arena in `BudgetAllocator`
over a limit-enforcing GPA. On the first refused allocation it prints KORU174
(budget + escape hatch) and exits(1) — the OS never gets to decide.

Measured after: the backend process on the 10-line program went 2.8 GB → 32 MB;
the 003_ecs benchmark completes end-to-end (was SIGKILL at 104 s) in 47 s;
the budget refusal is pinned by 220_030 (`--compile-mem-mb=1` → KORU174,
exit 1, no signal 9).

What would correct this: a program whose compile memory still scales with
store capacity or store count beyond the fixed AST+closure cost; a budget
refusal on a program the pipeline legitimately needs more room for (the
default 4096 MB must not fire on ordinary programs — the escape hatch is
`--compile-mem-mb` / `KORU_COMPILE_MEM_MB`); or a missed-invalidation bug
serving a stale flat list (symptom: minted declarations invisible — "unknown
store" with the declaration sitting in the file).

Open: Stage D (`zig build` of the emitted program, Debug by default) is its
own ~1 GB for small programs and scales with emitted size; the budget does
not cover it (a separate child process). Known, bounded — a separate
contract, not part of this one.
