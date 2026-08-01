---
type: belief
id: frag-a-store-declaration-is-a-lifecycle-dispatch
provenance: probed while designing a pump aggregator — asked what a store says about an arm outside its vocabulary
ts: 2026-08-01
---

# A store declaration is a general lifecycle dispatch, not a `! discharge` slot (belief)

`! discharge` reads like a bespoke escape hatch bolted onto `std/store:new` for
the one case the auto-discharger cannot settle. It is not. The declaration site
is an interceptor dispatch over a **vocabulary** — `discharge`, `inserted`,
`removed`, `updated` — and a name outside it is refused with a message that
prints the vocabulary back to the author. So the site is designed to grow: the
cost of a new lifecycle arm is a name in an existing dispatch plus its emitter,
not a new declaration form and not a parser change.

This is the update that matters for anything wanting to hook a store's rows.
A pump arm — "here is how a row ADVANCES", the sibling of "here is how a row
ENDS" — has been reading as new language surface. It is a fifth interceptor.

The corollary is the trap. **A name in the vocabulary is not a promise that it
fires.** `! removed` is accepted on a declaration and does not fire when a row
leaves through `std/store:take`; the program compiles, runs, and prints nothing
where the arm was. That is an accepted-but-silent surface, which is the shape
this project bans everywhere else — a reader cannot tell it from a wired one.
Whether `removed` is unwired or fires on some other removal path is not
established; only the silence is.

Open question: the vocabulary is closed and the refusal calls the rest "a later
slice", so the design already anticipates growth without saying what governs it.
Nothing states which lifecycle moments a store owes an arm for, so each addition
is argued on its own. A rule — every transition a row can make is nameable, or
these four are the transitions and the list is complete — has never been
written down.
