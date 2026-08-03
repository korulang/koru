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

## "Dead even with hand-written Zig" was a claim about a SHAPE, not about Zig

The sitting above raced the Koru binary against a hand-written Zig loop *of the
identical shape* and got a tie, and the sentence that came out of it — there is
nothing left to win inside this loop — quietly hardened into a ceiling: Koru's
ambition is to MATCH straight-line Zig. The ECS benchmark's
`bevy_strength_world` breaks that, in the direction nobody was watching.

It is the workload the borrowed harness's own README says is *intended to
favour Bevy ECS* — three entity kinds, bouncing dynamic bodies, dying particles,
trigonometric orbiters, three passes a frame. The Koru port runs it **1.2x
faster than the hand-written striped Zig baseline**, interleaved, and the
checksum is bit-identical across Koru, Zig and bevy_ecs, so all three are
provably doing the same arithmetic.

The reconciliation is that the earlier probe controlled for shape *by
construction*: it hand-wrote the loop Koru emits. A real hand-written program
does not do that. It picks its own shape, and at any size a human reaches for
the structure a human can maintain — here a struct of slices reached through
`self`, where the generator emits module-level arrays at statically known
addresses. That is a plausible reading of the 1.2x and NOT an established one;
`probes/ab_codegen.py` is the instrument that would settle it and has not been
pointed at this.

What the belief becomes:

- **A shape-matched race measures the emitter. It does not measure the
  competitor.** Both are worth running and they answer different questions;
  only the second one is what a user experiences, because a user compares
  against the program someone would actually write.
- **Hand-written host code is not an upper bound on generated code.** A
  generator has no maintainability budget: it can emit the layout, the
  indirection-free access and the aliasing-free globals that a person would
  refuse to hand-maintain. Treating the baseline as a ceiling silently caps the
  ambition at "as good as", and this workload says the ceiling was imaginary.
- **The ambition-shaped question is now open.** If generated code can beat
  hand-written host code on a realistic workload, the interesting comparison
  stops being the straight-line baseline and starts being *which shapes the
  planner is allowed to choose* — the same lever the fission and vector-cell
  entries above already name, arriving from the other side.
