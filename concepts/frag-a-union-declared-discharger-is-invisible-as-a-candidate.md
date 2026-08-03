---
type: belief
id: frag-a-union-declared-discharger-is-invisible-as-a-candidate
provenance: 2026-08-03, koruc 0.1.7. Pinned RED as 330_124. A single file declares `finalize { h: *Handle<!opened|closing> }` and leaves a bound `<closing!>` undischarged; KORU030 answers "No tor accepts <!closing>". The control — same file, `|> finalize(h: h2)` appended — compiles, runs, prints `finalized n=1`, and 330_051 is the standing green twin for both states of the union.
ts: 2026-08-03
---

# A union-declared discharger is valid as a call but invisible as a candidate (belief)

`<!opened|closing>` is the sanctioned way to write one disposer for several
states, and as a *call* it works exactly as advertised: the phantom checker
accepts a `closing!` value at that parameter and discharges it. As a *candidate*
it does not exist. The KORU030 candidate set is built from explicit `!state`
atoms, so an atom that is bare-inside-a-discharging-union never enters the index,
and the message then reports the strongest possible falsehood — that no tor
accepts the obligation at all — about a discharger declared three lines above the
flow, in the same file.

The diagnostic is the part worth fixing first, because it is wrong under every
remedy. Whatever the right answer for the *program* is — refuse it, or let
auto-discharge insert `finalize` (the frontier
[[frag-obligation-enforcement-keys-off-return-binding]] leaves open) — a message
that denies the existence of a discharger sends the author to write a second
disposer that already exists, or to conclude the union spelling is broken. The
message already has vocabulary for the honest case: `Call one of: …`, which is
what the same program prints for its `opened!` obligation. So the fix is
membership in an existing list, not new surface.

What this does NOT establish is that auto-discharge should insert here. That is a
claim about the *other* index — the inserter builds its candidates by EFFECT,
the message by SIGNATURE, and [[frag-a-red-pin-is-unfalsifiable-documentation]]
records what it cost the last time someone read one as evidence for the other
(`330_118` pinned a fault that did not exist). Both indexes happen to miss the
union here, which is suggestive of one root cause and is not proof of it. The pin
asserts the message only, deliberately, and asserts it with `NOT_CONTAINS` on the
falsehood so it cannot go green on a reworded lie.

Open: whether the union atom should also become an auto-discharge candidate. It
would not violate the one-disposer-per-obligation conservatism of
[[frag-auto-discharge-must-not-elect-among-disposers]] — in the pinned program
`closing` has exactly one candidate, so there is nothing to elect among — but the
surrounding frontier is contested and the ruling is Lars's, not the pin's.

How it surfaced is worth keeping: not from reading the compiler, but from drawing
korulang_org's phantom lifecycles as state machines. A per-carrier diagram makes
an unbalanced obligation *visible as a shape* — `closing` had an entry and no
exit — which is what prompted probing it at all. The first model behind that
diagram was itself wrong in the same place (it read the union's bare atom as a
hold, and duly reported `@korulang/openssl`'s `close` as leaking); the green
330_051 corrected it. The suite arbitrated both the compiler's claim and the
visualiser's.
