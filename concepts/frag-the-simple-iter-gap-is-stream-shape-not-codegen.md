---
type: belief
id: frag-the-simple-iter-gap-is-stream-shape-not-codegen
provenance: simple_iter_f32 profiling session 2026-07-31 — disassembly of the koruc-built binary, sample under load, and an equal-draw interleaved pure-Zig ceiling probe in scratch
ts: 2026-07-31
---

# The remaining simple_iter gap to legion is stream shape, not codegen (belief)

After the call-valued-index fix and the `for` conversion, the f32 `simple_iter`
sweep loop as emitted is **at the machine's ceiling for its own loop shape**.
Disassembly shows NEON `fadd.4s` over `q` registers, no bounds checks, `len`
loaded once for the entire timed block, every handler inlined (no call in the
loop; the announce/peek chain folds to nothing), and one instruction of
overhead beyond the minimum the operation needs. A hand-written pure-Zig loop
of the identical shape — six scalar `[10000]f32` columns in one global struct,
one fused pass — measures **dead even** with the Koru binary (ratios 1.00–1.05
across two interleaved min-of-30 sessions under load). There is nothing left
to win inside this loop.

What remains against legion is the *shape of the traffic*, chosen by the data
model, not by the emitter. The port declares six scalar columns, so the fused
sweep drives **six concurrent f32 streams**. Legion's entities carry four
components but the query touches two — Position (write) and Velocity (read) —
so their pass drives **two concurrent streams of 12-byte vec3 elements**. Same
bytes per pass (240 KB read + 120 KB write); different concurrent-stream
count. Measured same-load, equal-draw: the 2-stream shapes (packed 12-byte AoS,
or three split 2-stream passes) run **1.16–1.20x faster** than the 6-stream
fused pass. That is the bulk of the observed 1.33x; the residual ~10% is
protocol (criterion median on a different day vs in-process min). Hand
16-wide vectorization of the fused shape buys only ~5–8% — vector width and
unroll are not the lever; concurrent-stream count is.

Two levers would close it, both design work, neither a bug fix:

- **Loop fission in the sweep emitter** — three 2-stream passes measured at the
  legion shape's speed. Legal only when the store can prove the per-column
  writes independent, and it reorders row-major to column-major, which is
  observable wherever handlers watch writes. This is a planner decision, not a
  peephole.
- **A vector-cell column** (vec3 as one cell, the mat4x4/2-D-cell substrate
  direction) — reproduces legion's element grouping at the surface level, so
  the port stops paying for a data-model difference the benchmark never asked
  for.

The methodological point, again sharpened: the last third of a perf gap was
not findable by reading emit — the emit was already optimal. It took an
equal-protocol, equal-draw, interleaved ceiling probe to show the gap lives in
the workload's stream shape. Before chasing a codegen deficit, mirror the
exact loop shape in the backend language and race it; if they tie, the gap is
structural and the comparison itself is what needs examining.
