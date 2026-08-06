---
type: belief
id: frag-discharger-count-chooses-the-safe-default
provenance: porting celld's ownership lease and output gate to obligations (830_THE_WORLD/838 and /842) — the two slices wanted opposite defaults and got them from one mechanism without being asked
ts: 2026-08-06
---

# How many tors consume `<!state>` is a DESIGN DECISION about defaults, not a consequence of how many you happened to write (belief)

Auto-discharge reads as a convenience: forget the `free` and the compiler
inserts it. Under that reading, the number of dischargers a resource has is
incidental — an artifact of the API surface — and the "multiple discharge
options" error is friction to route around by nominating a primary.

Two ports landed the other way round. A **lease** has exactly one way back
(`cas.release`), so auto-discharge inserts it and a lease cannot be leaked even
by forgetting. A **response** has two (`gate.ack`, `gate.fail`), so the compiler
declines to choose and every request's fate must be written down. Both are the
behaviour that slice needed, and neither was designed in — they fall out of
counting the consumers.

**The durable claim: declaring how many tors consume `<!state>` is the act of
choosing whether an unattended resource has a safe default. One consumer asserts
"there is a right thing to do here, do it." Two asserts "no default is
defensible; make the caller decide."** That is a design decision with a
consequence, and it is currently made by accident, as a side effect of what the
API happened to need.

## Why the second case is the load-bearing one

An ambiguity error is easy to read as a gap — the checker being unable to pick.
Invert it: for a response, *both* defaults are lies. Auto-acking claims a
durability nobody proved; auto-failing discards a write that may have committed.
celld arrives at exactly this conclusion by hand, and pays for it: its fence
walks every gated write and completes each one as explicitly failed
(`logic/lib.rs:3838-3843`), a decision someone had to write, remember, and keep
correct as the code grew. Refusing to choose is not the checker's weakness. It is
the only honest answer, and getting it for free from the discharger count is the
result.

## What follows for library design

When adding a resource, ask what should happen if a caller forgets it — and then
express the answer as the number of consumers, deliberately. A second discharger
is not merely a second API; it **removes** the safety of forgetting. Adding
`fs:abandon` beside `fs:close` would silently convert every existing
forget-and-let-the-compiler-handle-it into a compile error across the corpus.
That blast radius should be a known cost of the design move, not a surprise the
next author discovers.

**OBSERVED 2026-08-06, one commit later, by accident.** The blast radius above
was written as a hypothetical about `fs:abandon`. Porting celld's node
self-fence then added `node.fence` beside `cas.release` — a second consumer of
`<!lease>` — and auto-discharge for leases went away across that whole program.
A control-flow arm that had been fine in `838`, where a forgotten release was
inserted for it, became `KORU030 multiple discharge options` and had to state
how authority ended. It is pinned as `830_THE_WORLD/848`.

Two things make this stronger than a worked example. It was **predicted before
it was seen**, in this file, one commit earlier. And it was **not constructed to
demonstrate the claim** — the fence port was after a different result entirely
and walked into this on the way. A hypothetical that fires unbidden on the next
piece of real work is the cheapest confirmation available, and this one cost
nothing to collect because the compiler reported it.

What the episode adds beyond confirmation: the cost lands on **existing, already
correct code**, not on the new API. Nothing about `cas.release` changed. The
call sites that broke had no relationship to fencing at all. So the design move
to be careful about is not "adding a discharger" in the abstract — it is that
the second discharger's cost is paid by *sites that predate it and do not
mention it*, which is exactly the kind of coupling that is invisible at review
time.

## Where this could be wrong

- **One discharger may not always be a safe default.** The claim assumes the
  single consumer is the right thing to do unattended. A release with an
  observable side effect nobody wanted at scope exit would break that, and the
  honest fix would be a way to say "one consumer, but never implicitly" — which
  does not exist today. Finding that case corrects this.
- **It may not scale past two.** Three consumers presumably also refuse, but
  "refuse" is then doing much less work than "make the caller decide between two
  meaningful outcomes"; the design guidance may only be sharp at n=1 and n=2.
- **It is induced from two ports in one afternoon.** Both came from the same
  source system, so the pair may reflect celld's taste rather than a general
  property of resources.
