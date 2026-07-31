---
type: belief
id: frag-two-lowerings-share-one-contract
provenance: introduced with the 400_177/178 emitter fix — curl's `! ?chunk` drain had no legal presence spelling at a splice site
ts: 2026-07-31
---

# An effectful proc's contract exists once per lowering, and a pin on one says nothing about the other (belief)

An effect-carrying proc is lowered TWO ways: as a module-level handler fn
(`handler(input, comptime __H: type)` — nested consumers, subflows, pump
attach) and as an inline splice into the caller's frame (top-level
cross-module consumers — the 400_176 note). Every contract the proc body can
see — presence probes (`@hasDecl(__H, …)`), unheard-arm stand-ins, `$mod.`,
`std.`, return/break shape — is therefore implemented twice, and the two
implementations drift independently.

The ruling held here: **a proc-visible contract is not pinned until it is
pinned on BOTH paths.** 400_154 × 833 pinned presence on the handler/template
path and the splice path for flow bodies; zig proc bodies on the splice path
had no working spelling at all until 400_177/178 — and the noop stand-in
beneath them contradicted the 400_145 never-evaluate ruling the whole time.
The corpus passed because top-level same-file consumers dodge the divergence
(400_176 documents the same one-sided coverage for payload types).

Open question: the divergences found so far were found by libraries growing
arms (curl `! ?chunk`, downloads' `! progress`). A systematic sweep — every
proc-visible contract × both lowerings — has never been run; each pin so far
is reactive.
