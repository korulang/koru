# Status

## Landed

- **Skeleton** — `benchmarks/` with workloads/, scripts/, results/, ENV.md, CAPABILITIES.md
- **Capability grid** (`CAPABILITIES.md`) — 8 capabilities × 10 languages, each cell a testable claim
- **Workload 1: sum_range_foldable** — 5 langs × 4 sizes. Finding: Koru + Rust both fold to closed form (~25ms regardless of n); C#/JS/Python scale linearly.
- **Workload 2: sum_range_xor** — 5 langs × 4 sizes. Finding: nobody folded; per-iter cost emerges (Rust 0.13 ns, Koru 0.32 ns, C# 2.1 ns, JS 33.7 ns, Python 37.1 ns).
- **Workload 3: multi_kind_dispatch** — 5 langs × 4 sizes. Finding: Rust still vectorizes, Koru's native multi-kind handles cleanly, JS/Python pay tuple-allocation tax (JS 50 ns, Python 96 ns vs sum_xor 33/37).
- **Workload 4: filter_map_reduce** — 5 langs × 4 sizes. Finding: no language folded the composed workload; Koru and Rust still vectorize; per-iter cost slightly increased.

## Parked / "for now"

- **OCaml 5 effects** — `ocaml` not installed locally. Would test sibling-abstraction performance (zero-cost vs runtime-dispatched algebraic effects).
- **Workload 5: allocations_per_yield** — needs per-language instrumentation (`GC.GetTotalAllocatedBytes` for C#, `tracemalloc` for Python, etc.). Real work, time-budgeted out of this round.
- **Nesting cost (workload 6)** — N×M×K total iterations, three nesting levels. Would test the "zero per-level dispatch tax" claim. Not measured.
- **Cold start / startup overhead** — implicit in results but not isolated as its own measurement.

## Issues collected

- **Koru prints via stderr.** `std.io:print.ln` lowers to `std.debug.print` which writes to stderr in Zig. Bench `run.sh` merges stderr into stdout. Worth flagging for users running real programs.
- **Dev-note channel drift.** Three posts using identical `node scripts/post-dev-note.js` invocation pattern landed in two different Discord channels. Mechanism unclear; not investigating mid-benchmark.
- **`if` at effect-branch body position resolves to Koru's `~if`, not Zig `if`.** Tried `! v p |> if (...) X else Y` in filter_map_reduce — error: "event 'std.control:if' invoked in pipeline". Worked around with branchless `@intFromBool` mask. Usability concern: users will reflexively type `if` expecting Zig semantics. Pin as failing test in a follow-up.
- **Capture transform doesn't integrate with effect-branch events.** Pinned in regression `400_098`. Sidestepped using producer-threaded resume values for benchmarks. Real fix is compiler-side work, deferred.

- **Workload 5: nested_3_levels** — 3 langs × 3 sizes (n=100/300/1000, total = n³). Finding: Rust folds the entire nested chain to a constant via `.count()` over fused `flat_map` combinators; Koru scales linearly with no per-level tax (0.34 ns/iter regardless of nesting depth); C# pays a 2x per-iter cost compared to flat workloads due to Enumerator allocation at level boundaries.
