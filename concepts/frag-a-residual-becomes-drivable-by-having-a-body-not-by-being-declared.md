---
type: belief
id: frag-a-residual-becomes-drivable-by-having-a-body-not-by-being-declared
provenance: 128 TODO comments and 66 parked tests in one tree; the parked tests have been machine-drivable for months and the comments never were, and the difference is not that anyone declared the tests
ts: 2026-08-11
---

# A residual becomes drivable by having a body, not by being declared (belief)

The intuition when you want to get rid of residual — leftover intent that never
became code — is to make it first class: give it a surface, a name, a listing.
Then a machine can enumerate it, an agent can be pointed at it, and it drains.

That intuition is half right and the half it gets wrong is the half that does
the work. **Declaring a residual makes it visible. It does not make it
decidable.** Something has to be able to run and return a verdict, and a
declaration is not that — it is prose in a different font.

The proof was already sitting in this repo before the surface existed. Two
populations of residual, both large:

- **66 regression tests parked behind a `TODO` marker.** The harness skips them
  before compiling and counts them in their own column. `scripts/todo_sweep.sh`
  drives every one of them, on demand, with no human in the loop.
- **128 `// TODO:` comments** — 88 in `src/`, 40 in `koru_std/`. Nothing drives
  them. Nothing ever has.

The sweep does not read a single word of a parked test's prose. It runs the test
and reads the verdict marker. That is the entire mechanism, and it works on the
tests for one reason only: **a test has a body.** A comment does not, so the
gap is not one of declaration or formality or tooling attention. It is
ontological, and no amount of ceremony closes it.

So the useful axis for a residual surface is not *is this a defect or a
roadmap*, which is what I reached for first. It is **does this have something
that can decide it, and if not, can we give it one.** A declaration earns its
place by being the act of attaching a body — in `koru_std/todo.kz`, an `owed`
residual names a witness test, and the reader refuses the declaration if that
test is missing, absent from the corpus, or asserts nothing.

## The corollary that makes it a filter rather than a chore

A residual you cannot write a failing test for is one you do not yet understand
well enough to declare. Five sites in `src/` say *clone if needed* or *might
need to deep copy this* and not one names the condition under which it is
needed; they are undecidable from their own text and they are exactly where an
aliasing bug would hide. The right disposition for those is to stay comments
until someone can say what would break.

This is why the entry fee is not bureaucracy. It is the only thing separating a
residual queue from a wish list.

## Why the entry fee cannot be waived, measured

On its first run the sweep found three parked tests passing and **none of them
promotable**. Two were `MUST_RUN` with no expected output — which asserts only
that the binary exited zero — and both printed the exact error their note said
they were parked on. The third pinned nothing at all and "passed" by compiling.

A driver pointed at residuals with no real assertion does not close them. It
manufactures victories, which is green-by-edit with a work queue attached and is
strictly worse than the honest comments it replaced. Any residual surface that
does not refuse the unwitnessed case is a machine for laundering unfinished work
into finished-looking work.

## The second-order risk: sanction

There is a real cost to making residual first class that the mechanics above do
not address. A blessing makes a thing comfortable. Convert 128 grep-findable
comments into 128 sanctioned tickets and you may have built a tidier permanent
home for them rather than an exit.

The mitigation has to be structural rather than disciplinary: **asymmetric
ceremony.** The residual you want at zero is the one that costs a declaration
and appears in a count; the harmless roadmap note stays a free comment. If both
are equally easy to declare, the surface is a nicer TODO list.

## What the surface bought immediately, and it was not retail

The expected payoff was one-residual-one-fix. The actual payoff was clustering:
**41 of the 128 hang on three yes/no questions** — whether an optimizer layer
exists (21), whether taps are a real feature or an abandoned experiment (14),
and whether the compiler-control protocol is alive (6). None of the three can be
closed by building anything; each needs a ruling, after which its whole cluster
evicts mechanically, dead stubs included, in one commit.

That is a second disposition with a different closer, and it is why
`koru_std/todo.kz` has `doubted` beside `owed`. A residual whose blocker is an
unanswered question is not debt — it is a decision nobody is making, and filing
it as debt guarantees it is never made.

## Open

- Whether `doubted` earns its keep long-term or collapses into "ask Lars", which
  the batons already do. It survives its first outing because the eviction
  leverage is concrete and large.
- Whether the sanction risk is real here. Watch whether the declared count grows
  faster than it drains; if it does, the ceremony is not asymmetric enough.
- The five copy-tree sites remain undeclarable by construction. That is the
  honest answer, not a gap in the surface — but it does mean a residual surface
  can never be a complete inventory, and anyone reading its count as one is
  reading it wrong.
