---
type: belief
id: frag-a-transform-fixed-point-is-per-site-and-budgeted
provenance: session 2026-08-15 — the store scale wall (game world population)
ts: 2026-08-15
tags: [koru, transform-runner, scale]
---

# The transform fixed point is ONE transform per pass, and the budget was a latent wall (belief)

The transform runner's fixed point applies exactly ONE transform per pass
(`walkOnce` returns after the first found, for deterministic single-write
ordering), so a program with N transformable sites needs N passes — and a
fixed 1000-iteration cap silently banned every legitimate program with more
than ~1000 sites. Measured 2026-08-15: a store with 128/256/512 literal
`insert` flows compiled in 6/10/21s (superlinear per-pass cost, O(N²)-ish);
1024 flows died with `TransformInfiniteLoop` after 58s — it was not
diverging, it was past the budget. The cap is now 100_000 and the message
says "budget," so 1024 compiles (68s) and a true re-firing loop still
terminates loudly after a bounded burn. The genuine fix — the quadratic
cost — is batching independent sites into one pass, which the single-write
ordering discipline currently forbids.

The blessed bulk path for large data is the LOOP form
(`for(0..N) ! each i |> insert(...)`): a single flow, a single pass, and
STILL O(runtime) rows — a 1,000,000-row store compiles as one site. Literal
per-flow population (1024 `insert` lines) is the anti-pattern that exposes
the wall.

What would correct or retire this belief: the runner learning to batch
independent transform sites per pass (killing the quadratic barrier), or
site-limit becoming irrelevant because the loop form fully covers bulk
population and the literal form is deprecated.