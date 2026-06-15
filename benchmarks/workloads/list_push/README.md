# Workload: list_push

## Question

Is `std/list` (the Koru collection — phantom-tracked events over `std.ArrayList`)
a zero-cost abstraction vs hand-written Zig `std.ArrayList`?

## Shape

- Push N=50,000,000 i64 into a list, report `len`, free.
- Koru: `std/list:new(i64)` → `for(0..N) ! each _ |> push(xs,1)` → `len` → `free`.
- Zig reference (`zig/main.zig`): `std.ArrayList(i64)`, `append` N times, print len.
- **Fairness:** both use `GeneralPurposeAllocator(.{ .safety = true })` (what
  `koru_allocator()` emits) and are built `-OReleaseFast`. The koru binary timing
  sits next to Zig-ReleaseFast and far from Zig-Debug, confirming it's optimized.

## Result (2026-06-15, hyperfine, 12 runs, M-series mac)

| impl                 | mean      | user    | system  |
|----------------------|-----------|---------|---------|
| Zig std.ArrayList    | 227 ms    |  72 ms  | 149 ms  |
| Koru std/list        | 288 ms    | 114 ms  | 161 ms  |

**Zig is 1.27× ± 0.14 faster.** NOT zero-cost. The overhead is in **user CPU**
(114 vs 72 ms, ~58% more) — the per-push event-handler dispatch — while system
time (allocation) is ~equal. Wall-clock dilutes to 1.27× only because the
workload is allocation-bound.

## Finding / next

The push handler (`push_event.handler(.{ .xs, .v })`) is not fully inlining away.
A candidate optimization: mark thin stdlib event handlers `inline` (or have the
emitter inline single-call wrappers) and re-measure — the hypothesis is that
closes most of the user-CPU gap toward parity. Honest status: near-parity in
order of magnitude, measurable single-digit-to-~27% overhead today.
