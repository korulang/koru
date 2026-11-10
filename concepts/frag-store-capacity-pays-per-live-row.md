---
type: belief
id: frag-store-capacity-pays-per-live-row
provenance: session 2026-11-10 — Nick Barker memory-series discussion;
  measured ladder on macOS arm64 (Darwin 25.5.0): koruc-built stores at
  capacity 16777215 across declared extents (RSS via /usr/bin/time -l),
  bulk-insert spike + std/store:clear + mid-sleep RSS resample, dyld
  launch bisect char[120..124], Zig struct-limit refusal at char[4096]
ts: 2026-11-10
tags: [koru, store, memory, mmap, benchmarks]
---

# Store capacity is a bound on rows — the memory bill is per live row, lazy inbound and sticky outbound

The folk model — declaring capacity preallocates RAM — is measurably
false on the native target, and the reason is that the store never asks
the OS for anything at declaration. Its SoA columns emit as `[CAP]T =
undefined` inside one static struct: bss, demand-zero pages. Nothing
allocates, nothing memsets, nothing commits. The kernel faults a page
on first write and owns it until exit.

Measured this session (macOS arm64, `capacity: 16777215`, the row
ceiling):

- ~384MiB declared (3×i64 columns), 2 live rows: whole-process peak RSS
  ~1.6MB.
- 1M rows bulk-inserted into the same store: peak RSS ~24.5MiB —
  approximately exactly the cells written. The bill tracks live rows,
  not declaration.
- `std/store:clear` then emptied every row; RSS sampled seconds later
  was still ~24.5MiB. Swap-remove recycles slots; pages never come
  back. High-water is sticky for process lifetime — lazy inbound,
  permanent outbound.

The envelope is real and loud, in three independent places:

- Rows: the handle packs slot|generation in i64 under an 8-bit store
  brand — `new` refuses capacity above 2^24−1 (690_196 lineage).
- Struct: Zig refuses a store struct over ~4GiB — "struct layout
  requires size … supports up to 4294967295" — at backend build.
- Launch: on macOS arm64 a store whose columns push the emitted
  `__DATA` vmsize past ~2.08GB produces a binary dyld aborts at exec
  (shared-cache map failure) — bisected at max capacity: char[123]
  launches (vmsize 2,063,640,256), char[124] aborts (2,080,397,632).
  Linux past that boundary is unmeasured, and the threshold may be
  OS-version- or machine-specific — one data point, not a spec.

And the laziness is Zig-target-only: JS emits `new Array(CAP).fill(…)`
per column — eager O(CAP) writes — and C# `new T[CAP]` — eager
zero-init. On managed targets capacity IS a bill.

The position is stronger than the usual lazy spell. `undefined` columns
under `len`-gated reads mean nothing needs an initial value at all —
there is nothing to prove freshness *for*. That is strictly lazier than
calloc/page_allocator paths, which must establish zero-ness, and far
lazier than Java/C# semantics that require zero-init on a reused heap
(physical commit proportional to declared extent). Go's `needzero`
span flag and glibc calloc's fresh-mmap check are the same trick in
narrower form; the store doesn't even need the trick.

The interpretation that matters: O10's capacity ruling was never a
memory decision — "silent autogrow is the exact shape the no-silent-perf
ruling kills" — and the measurement confirms it. Capacity is a
structural bound that makes worst-case memory a compile-time fact and
exhaustion an explicit `| full` branch; the laziness is inherited from
the OS substrate for free. Sibling:
frag-extent-pays-per-touch-not-per-declaration — the grid/pool face of
the same mechanism; this is the store face plus the boundaries.

What would correct this: a backend or target where store declaration
eagerly commits physical memory; give-back landing (madvise/decommit
on dead column tails) falsifying sticky-outbound; a platform where
>~2.08GB-`__DATA` stores launch; or the row cap moving.

Open questions: whether a `shrink`/`compact` verb — page-aligned
madvise of column tails past `len` — is worth building (only against a
measured RSS-retention workload); whether runtime-extent stores
(slice columns à la grid:pool) ever pay their measured access tax;
whether `store:new` should refuse declared extents past the launch
envelope at compile time instead of shipping an unlaunchable binary.
