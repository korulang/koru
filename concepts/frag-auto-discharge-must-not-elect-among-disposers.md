---
type: belief
id: frag-auto-discharge-must-not-elect-among-disposers
provenance: surfaced while designing the curl async surface (`| pending` / `| done` on one tor); probed against a two-disposer obligation
ts: 2026-07-26
---

# Auto-discharge may insert a disposer, never elect one (belief)

Auto-discharge is safe to leave on by default because of an unstated premise:
that the discharger it inserts is the *only* one it could have inserted. Where
an obligation admits exactly one disposer, insertion is a mechanical completion
of the author's intent, and the author would have typed the same call.

That premise is load-bearing and it is not enforced. Given two disposers for the
same obligation the pass picks one and compiles clean, with no diagnostic.

## Why the distinction is not pedantic

Disposers are not interchangeable. They are the vocabulary in which a resource's
*outcomes* are spelled, and a resource with two of them has two of them because
they mean different things. The shape that surfaced this — a pending async
operation offering `drain` (carry the work forward) and `cancel` (abandon it) —
has disposers that are near-opposites. Electing between them is a semantic
decision about what the program should do, and the elected answer is invisible:
it appears in neither the source nor any diagnostic.

The general rule this instance argues for: a pass may complete what the author
*must* have meant, never choose what they *might* have meant. Completion is
service; election is authorship, and authorship belongs to the author.

## The compiler already knows

This is not a missing analysis. Under `--auto-discharge=disable` the existing
KORU030 enumerates every candidate in as many words ("Call one of: …"), so the
candidate set is computed and the ambiguity is visible at the moment of
insertion. It is then discarded. The fix therefore wants no new diagnostic and
no new machinery — only that insertion declines when the candidate set is not a
singleton, and lets the sentence the compiler was already prepared to say
through. Pinned by `330_118`.

## Why it survived

Nothing in the corpus declared two disposers for one obligation, so the premise
was never tested. `330_025` pins the single-disposer case, which is precisely
where the behaviour is right, and every other obligation test inherits that
shape. A default-on convenience is examined at the point it fires, and it fired
correctly everywhere anyone looked.

## Open

Whether "not a singleton" is the right test, or whether a disposer should be
able to *declare* itself the default for its obligation (making a two-disposer
resource legal to auto-discharge again, deliberately, at the library author's
word). The second is more expressive and is the kind of thing the closed-scope
ruling in [[frag-no-threads-at-surface]] would favour — the event governing its
own contract — but it adds surface, and the conservative rule buys the
correctness now. Undecided; the pin only demands that silence stop.

Related: [[frag-obligation-enforcement-keys-off-return-binding]] (whose frontiers
are all about whether enforcement is *reached*; this belief is about what
insertion does once it is), [[frag-no-fallbacks]] (a silently elected disposer is
a substitute output standing in for a decision that was never made).
