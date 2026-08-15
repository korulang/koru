---
type: belief
id: frag-a-transform-fixed-point-is-per-site-and-budgeted
provenance: session 2026-08-15 — the store scale wall (game world population)
ts: 2026-08-15
tags: [koru, transform-runner, scale, emitted-size]
---

# The transform fixed point is per-site and budgeted; the TIME wall is the final Zig ReleaseFast build (belief)

Two separate scale costs on a program with N literal transform flows, and
they have different fixes and different shapes:

1. THE PASS BUDGET (crash, FIXED 2026-08-15). The transform fixed point
   applies ONE transform per pass (`walkOnce` returns after the first found;
   deterministic single-write ordering), so N transformable sites need N
   passes, and the loop breaker was a FIXED 1000. A store with 1024 literal
   `std/store:insert` flows (no kernel) is a finite program needing >1000
   passes — it died with a misleading `TransformInfiniteLoop` after 58s of
   finite work. The breaker is now an honest budget (100_000) with a message
   naming both readings; 1024 flows compile (~68s); a genuine re-firing loop
   still terminates loudly after a bounded burn.

2. THE TIME WALL (measured, NOT the passes). The passes themselves are
   FAST: at 512 flows the transform phase completes in ~0.7s. The other
   ~19s of a 20.4s compile is the FINAL `zig build-exe output_emitted.zig
   -O ReleaseFast` of the emitted program, which grows with the flow count
   (512 literal inserts emit a ~6.5MB file — ~12KB per insert flow's
   synthesized event+proc machinery). So the compile time for literal
   per-flow population is dominated by Zig's ReleaseFast build of the big
   emitted artifact — near-linear in emitted size, not a transform-pass
   quadratic. Any "batching" fix to the runner would NOT move this wall.

The blessed bulk path stands and bypasses BOTH: the LOOP population form
(`for(0..N) ! each i |> insert(...)`) is ONE flow, ONE pass, and a small
emitted artifact — a 1,048,576-row store compiles near-instantly while a
literal-1024 population takes ~68s. Literal per-flow population is the
anti-pattern for large data.

What would correct this belief: the runner batching sites per pass would
only matter past the budget, which is already fixed; the time wall would
correct by emitting less per flow (the insert flow's ~12KB/flow machinery)
or by not forcing -O ReleaseFast on the intermediate build.