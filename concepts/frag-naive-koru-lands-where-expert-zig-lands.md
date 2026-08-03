---
type: belief
id: frag-naive-koru-lands-where-expert-zig-lands
provenance: boids, 2026-08-03 — Koru ran a borrowed DOTS workload at 98ms against a hand-written striped Zig baseline's 217ms, and the root-cause investigation found the baseline is scalar for two reasons that must BOTH be fixed and that Koru satisfies without anyone deciding to
ts: 2026-08-03
---

# The claim was never "Koru beats Zig" — it is that naive Koru lands where EXPERT Zig lands, and the expertise is undiscoverable (belief)

A borrowed workload — Unity DOTS' BoidSystem, their constants, our port, a
bit-identical checksum across four implementations — ran 2.2x faster in Koru
than in hand-written striped Zig. That number is real and it is the wrong thing
to quote, because the baseline is not what a Zig expert would ship. Fixed, it
comes within a small factor. **The interesting quantity is not the gap to the
baseline; it is what a Zig programmer must KNOW to remove it.**

## What the baseline had to know

The Zig loop is scalar. Making it vectorise requires two independent conditions,
and the shape of that requirement is the finding:

- **A — no control flow in the per-element body.** `normalizesafe` branches on
  the degenerate-length case and returns an aggregate from each arm. LLVM will
  not if-convert that, so the loop keeps a branch and stays scalar.
- **B — provable non-aliasing.** The columns arrive as heap slices, so the
  compiler cannot prove the writes do not disturb the reads.

**Neither buys anything alone.** Fixing only the aliasing is noise. Fixing only
the control flow is WORSE than doing nothing — it pays an unconditional square
root and a divide for a vectorisation that does not arrive. Only the conjunction
flips the loop to 4-wide, and then it flips hard.

That is a brutal discoverability property. A programmer who suspects the branch,
converts it, measures, and finds it slower will rationally revert — and having
reverted, will never see what the second change would have bought. The road to
the fast version passes through a state that measures worse than the start.

## Why Koru is on the other side of that cliff without trying

Koru satisfies both conditions by construction, and neither is a performance
feature:

- **A falls out of having no expression-local binding.** With nowhere to name an
  intermediate, each vector component is written as its own scalar expression,
  so the degenerate case becomes three independent scalar selects rather than
  one branch returning an aggregate. Three selects if-convert; one branch does
  not.
- **B falls out of second-class-ness.** Columns are module-level arrays at
  statically known addresses, so there is no aliasing question to prove.

The irony is worth keeping: **the verbosity is the optimisation.** The same
missing binding that turned forty lines of C# into twelve thousand characters of
Koru is what produced the if-convertible shape. Nobody designed that, and an
"improvement" that added expression-locals could take the vectorisation away
unless it preserves per-component independence. That is now a constraint on a
feature we were about to want.

## What this licenses us to say, and what it does not

- NOT "Koru is 2.2x faster than hand-written Zig." That compares against a
  baseline with a fixable defect, and someone will fix it in public.
- NOT "our data model makes us fast." Measured directly: giving the Zig baseline
  Koru's exact static-array model, alone, changed nothing in the hot phase. The
  aliasing story is necessary and nowhere near sufficient, and stating it alone —
  which this repo's own benchmark README did for a different scenario — is
  wrong.
- YES: **a naive Koru port matched a Zig program that required two non-obvious,
  non-incremental, mutually-dependent expert interventions to reach.** The
  performance is not in the emitter being clever; it is in the language making
  the wrong shape unspellable.

That is a much better claim than the one the number invited, and it is the claim
the project has actually been making all along.

## Open

- Whether the same conjunction explains the other scenario where Koru leads a
  hand-written baseline (`bevy_strength_world`, 1.2x, cause recorded as
  unestablished). The aliasing hypothesis parked there is now known to be
  insufficient on its own, so that entry should be re-opened rather than
  inherited.
- What an expression-local binding must preserve to keep A. If it lets an author
  compute one shared intermediate and branch once on it, it hands back exactly
  the shape that does not vectorise.
- Whether any of this survives a workload whose per-element body has genuinely
  unavoidable control flow. Boids does not have one; something with early-out
  per element would.
