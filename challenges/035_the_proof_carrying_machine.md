---
challenge: proof-carrying-worklist
kind: frame
status: standing
yields: Koru lowers effectful and obligation-carrying regions onto the
  stealable worklist machine — not just proven-pure self-recursive tors —
  with proofs riding the work item, expanding machine coverage by
discharging more proof classes rather than weakening any check
catalog: none — generative, opens a family (evaluation-strategy lowerings)
family: performance / semantics
created: 2026-11-23
---

*Commissioned 2026-11-23 after the fork-economics replay (034) proved the
thesis on its first cell: the compiler picked the evaluation strategy and
fib-par went 41.2 → 19.8ms, under the bend-par bar (29.23).*

*What Bend actually is (read from `~/.bend/app/2.0.5/.../comp.ts`,
6.2k lines TS → C/JS): every call defunctionalizes into `Fid` worklist
states dispatched by `work_loop`/`wl_tab[]`; terms are one-word tagged
pointers; per-worker rings + `monk_step` + `task_deal` steal continuously
— granularity is per-reduction-step, which is why it self-balances skewed
trees. `seq` is a flag in the same binary. Effects are not special: `IO`
is a `base.bend` monadic type compiled to worklist states (`FID_IO_EMIT`)
serviced by a host loop over `effs/*.c`. The same `monk_step` runs the
GPU kernel — one IR, three machines.*

*The honest gap this challenge exists to close: Bend's machine is TOTAL
because its effects were born as machine states (`IO.OP`). Koru's effects,
obligations, stores, and handles are compiler-level proofs — richer than
Bend's type-level IO discipline, but with no term-level encoding, so they
cannot ride the machine. Today's worklist lowering (`a23a1ef03`) fires
only for proven-pure self-recursive tors; the purity gate is the honest
edge of what we can currently encode.*

*This is not "invent Bend's IO" — Bend's `IO.OP` is the crude prototype.
Koru already has the real semantics as proofs; the work is a projection of
existing proof structures onto machine states, which is what compilers
do. Sanity advantage over Bend: no new surface syntax (proof metadata
already exists), proofs ride the work item as witnesses (Bend's unchecked
lowering can't claim that), and coverage expands by discharging more
proof classes — never by dropping a check.*

---

## The brief (sealed — you are the contestant)

**Give Koru's proofs machine legs: encode effect/obligation/store semantics
as worklist states so the lowering coverage map grows by proof, not by
exception.**

Rung 1 (landed, `a23a1ef03`): proven-pure self-recursive `[parallel]` tors
lower to a per-event `__wl` deque — depth-gated push breadth
(`WL_PUSH_DEPTH=12`), single shared deque, done-count joins. Measured:
coins-par 37.3ms±4.7 loaded (min 29.2, bar 33.2), fib-par ~34 needs
quiet-box comparison vs fork/join's 19.8 — selection rule between the two
mechanisms is an open sub-question (candidate: fire worklist only on
asymmetrically-decreasing self-calls).

The work ahead, in dependency order:

1. **Work-item schema.** Today an item is (continuation, args). Design
   the carrier for proof witnesses: discharged obligations, effect
   contracts, store accesses, ownership tokens — as data the machine can
   sequence. Study how Bend encodes `IO.OP` terms → `FID` states →
   `effs/*.c` host shims; the Koru version must carry *proofs*, not just
   effect tags.
2. **First effectful class.** Pick the smallest semantic class that
   survives lowering honestly — candidates: pure-but-effectful tors
   (declared effects that commute), store reads vs writes (ownership
   decides sequence), handle resolution. Prove the encoding preserves
   obligation discharge order; a worklist that reorders effects
   incorrectly is a correctness bug, not a perf bug.
3. **Coverage expansion.** Mutual recursion, non-self pure tors, then
   effectful tors as classes 1–2 land. Each expansion is gated on the
   proof that class requires — the purity gate becomes a coverage map:
   report which semantic classes lower vs stay native, with the witness
   each lowering carries.
4. **Scheduler convergence (optional rung).** The `__wl` deque is the
   seed of monk_step's ring-stealing; if measurements justify, adopt the
   ring/task_deal shape for finer steal granularity. Do not build this
   before 1–3 prove the encoding — granularity without semantics is the
   wrong order.

Invariants (hard):

- **Sequential parity** — non-lowered regions emit unchanged code; seq
  twins must not regress.
- **No weakened checks** — coverage grows only by discharging proofs.
  A lowering that can't carry a proof stays native and says so.
- **No new surface syntax** — the encoding is compiler-internal
  projection of existing proofs/annotations.
- **Oracle-green always** — fib 9227465, coins 116727, plus whatever new
  effectful benchmark kernel the work needs (write it oracle-first).

Done-gates:

- At least one effectful/obligation-carrying tor lowers to the worklist
  and runs oracle-correct under parallel execution.
- A coverage report: which Koru semantic classes now lower, which stay
  native, and the proof each lowering carries.
- No regression on the Osprey cells already won (fib-par ≤ ~20ms quiet,
  coins-par ≤ 33.2ms, all seq cells).

---

*Meta-note for the walker: this challenge is the "compile to that idea"
escalation made concrete. Bend proved effects can be machine states via a
monad; Koru's version carries discharged proofs as work-item witnesses.
The prize isn't matching Bend's board — it's being the language that can
express Bend's entire evaluation idea *plus* the semantics Bend simulates.
If this lands, "language-language" stops being a claim and becomes a
coverage map.*
