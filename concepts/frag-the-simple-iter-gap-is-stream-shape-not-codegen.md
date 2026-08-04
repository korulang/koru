---
type: belief
id: frag-the-simple-iter-gap-is-stream-shape-not-codegen
provenance: simple_iter_f32 profiling session 2026-07-31 — disassembly of the koruc-built binary, sample under load, and an equal-draw interleaved pure-Zig ceiling probe in scratch. EVOLVED 2026-08-03 by the boids investigation, which closed the open question at the end of this file with a measurement in three languages and a named mechanism.
ts: 2026-08-03
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


## The open question closed: layout is the compiler's call, and second-class-ness
## is what licenses it

The entry above left this open — *"which shapes the planner is allowed to
choose"* — and named it ambition-shaped. Boids closed it, and the answer is
narrower and better than ambition: **for a second-class container it is not an
ambition at all, it is an unimplemented ruling.**

The store design already says it, in one line predating this measurement:
*"layout is the closure of the queries — projections become SoA columns,
predicates become maintained views."* `std/grid` does not honour it. It emits
nine parallel columns unconditionally, whatever the program does with them.

What boids adds is the price, measured three ways on the same workload and the
same checksum: packing a grid cell into one record instead of nine columns is
worth **9.67 ms in C** (94.92 -> 85.25), **8.95 ms in Zig** (scatter 35.6 ->
26.8), and **1.66x on the scatter phase** in a controlled Rust A/B. Roughly 10%
of the frame, agreed across three independent implementations. It is the
largest single item on the board and the only one that is not codegen.

**Why Koru can decide this and C cannot**, which is the part worth keeping:

- Columns are DECLARED, not allocated. The set is comptime-closed.
- Every access site is comptime-visible — the store transform already walks
  every reference in the program to compile subscriptions into the write path.
  The planner's input is already collected, for another reason.
- No pointer to a column escapes. Second-class-ness means the layout is
  **unobservable to the source**, so changing it is not a semantic change.

That third point is the load-bearing one and it is the same argument as
`frag-second-class-is-what-makes-a-container-disappear`, arriving from the
performance side: a container you cannot hold a reference to is a container the
compiler may re-lay-out freely. A C or Zig programmer must pick by hand and
live with the choice everywhere; Koru has the information and currently throws
it away.

**It is a clustering, not a toggle**, and this workload is the argument because
it wants both answers at once. The scatter touches seven fields of ONE cell at
a random index — seven cache lines where a record needs one, so it wants AoS.
The resolve sweep reads one field across ALL cells, so it wants SoA, and Koru
wins that phase today (1.83 ms against 2.3). A global switch would trade one
for the other. Grouping co-accessed fields is what "the closure of the queries"
already means, and it is exactly what the walk can already see.

The falsifiable part: if a co-access clustering is implemented and boids does
NOT land near 90 ms, then either the ruling does not mean what this entry reads
it to mean, or the walk is not seeing every site — and the second would be a
correctness bug in the store, not a performance disappointment.

**And the analysis is not on the critical path, because the annotation already
is** (ruled with Lars 2026-08-03). If co-access clustering turns out to be hard
to infer — or the codegen to honour it is hard — the same mechanism that landed
`[unsafe(bounds)]` carries it: a parameterised prefix annotation on the
declaration, `std/grid:new` and `std/store:new` being flow sites that already
accept `ast.Flow.annotations`, parsed by the compiler's own
`annotation_parser`, with `310_031`/`310_033` as green precedent and zero
grammar work. It should refuse an unknown facet the same way, for the same
reason: a typo that silently waives nothing is worse than one that errors.

That makes the inference OPTIONAL rather than blocking, which is the right
shape for a decision this cheap to state and this expensive to derive. The
store design anticipated exactly this — it wants the surface so that things
"currently INFERRED" can be DECLARED, and names the dense cursor as a codegen
decision the author cannot presently express. Layout is the second instance of
that same gap.

## BUILT, 2026-08-04, and the prediction held

`[layout(row)]` shipped on `std/grid:new` the morning after this was written,
and the falsifiable clause above is now settled: **boids landed at 91.5 ms**
against 98.7 column, interleaved, checksum unchanged. "Near 90 ms" was the bar
and it cleared it. The walk does see every site.

It cost THREE EDIT SITES in one file, and the reason is worth keeping because
it is the payoff of an earlier repair rather than luck: `grid.kz` has exactly
one address formatter, reached by every read AND every write, because that
duplication was collapsed the day before
(`frag-a-fix-lands-in-one-lowering-path`). A second lowering would have meant a
second place to teach, and the two would have drifted. The cheapness of this
feature was bought weeks earlier by someone deleting a copy.

**The store is NOT the same job, and the count says so:** it spells
`__koru_store_{s}.{s}[__koru_r]` in twenty-odd generators across 8,692 lines,
none unified. It is also the wrong target — the store's premise is the dense
vectorising sweep, which is precisely what row layout destroys. The grid is the
thing that gets scattered into. Cheap and correct pointed the same way here,
which will not always be true.

**The losing direction is now on the board too** (`004_grid_layout`), and it is
much larger than the win: a sweep reading one field of nine runs 0.04 s column
against 0.45 s row, ~11x. So the honest shape of this trade is ASYMMETRIC —
row buys single digits on a scatter and costs an order of magnitude on a sweep.
Anything that ever infers this must weight it that way, and the default must
stay `column`.

That asymmetry also sharpens the clustering argument rather than softening it:
a per-table flag on a table with both shapes is not a compromise, it is a
coin-flip between a 7% win and an 11x loss.