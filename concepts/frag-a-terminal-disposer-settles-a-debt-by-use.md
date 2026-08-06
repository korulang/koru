---
type: belief
id: frag-a-terminal-disposer-settles-a-debt-by-use
provenance: fell out of flipping enforce_debt_exists (Lars's 2026-08-06 ruling) — the strict linear-transfer reading refused 335_050/051, the greenest disposer idiom in the corpus, and the discriminator that separates them from 330_125 is reference, not consumption
ts: 2026-08-06
---

# A terminal disposer settles a transferred debt by USE — the silent-drop wall is reference-based, not a linear proof (belief)

The linear-transfer ruling (2026-07-02) reads strictly: a consumed obligation
enters a pure impl body live, and the checker proves it discharged exactly once
— onward consume, or issuing output branch — "a drop leaks loudly." Taken at
the letter, that refuses `release = std/io:print.ln("release {{ name:s }}")`
(335_050/051): a terminal disposer whose body neither consumes onward nor
issues. But that body is the bottom of the chain. There is no lower discharger
to route to — for the bottommost consuming tor, **the body's use of the value
IS the implementation of the discharge**. A pure body cannot destroy a
resource; purity means it can only route, and at the bottom there is nowhere
left to route.

So the enforceable wall is against the **silent drop**: an impl body that never
references the consuming binding at all — not as an argument, not in a
condition, not through an interpolation (330_125's `drop-it = note(n: 1)`).
Reference-based is weaker than the linear proof — a body that only borrows the
binding and returns still leaks past it — but it is the strongest wall that
does not refuse the corpus's canonical disposer idiom, and the test errs toward
"referenced" so a coincidental mention only suppresses the wall, never fires it.

Two load-bearing facts underneath, both measured 2026-08-06:

- The debt-exists predicate (`<!state>` requires the provided value to owe)
  and the delegation case (`pass-through = sink(h)`) are separated by the
  impl-param seeding threading the marker in as `state!` — that is what tells
  "I was given this" from "I was only shown this" (335_054/055).
- The marker died in **canonicalization**, not at the seed site:
  `canonicalizePhantomState`'s concrete arm re-renders `module:state` keeping
  only the issue suffix, so a consume prefix does not survive it (the union
  arm preserves it — the asymmetry was the bug). Residual trap: any OTHER
  caller that parses a canonicalized string to read consume markers reads
  a lie. Read markers off the raw spelling.

Open, and Lars's: whether the borrow-only drop (referenced but never consumed,
never issued) should eventually refuse too — that is the gap between this wall
and the ruling's letter. Pins: 330_125, 335_054, 335_055 (all closing),
335_050/051 (the idiom that forced the discriminator).
