---
type: belief
id: frag-the-vocabulary-wall-guards-drift-not-defiance
provenance: kopium-headless/live.k driving the resource bridge from a live claude-haiku-4.5, 2026-08-07 — five out-of-vocabulary requests probed, five declined in prose; the one `event-denied` ever produced by a live model turned out to be a parser defect (pinned 430_055)
ts: 2026-08-07
---

# The agent's vocabulary wall guards drift, not defiance (belief)

`std/runtime:register(scope: …)` declares what an agent may invoke, and an event
outside it comes back `event-denied`. We built that expecting the misbehaving
model — the one that reaches past its tools. That model did not turn up.

Measured against claude-haiku-4.5: asked five times to do something outside its
three verbs — read, flush, rename, truncate, delete — it declined in prose five
times and never once invented an event name. A cooperative model does not name
a verb it was not given. It refuses, or it substitutes a verb it *was* given
(asked to truncate, it emitted `close`, which is wrong and legal).

So the wall's designed traffic is zero, and that has a nasty property: it makes
the wall look exercised. The single `event-denied` a live model has ever
produced came from prose parsing as an invocation — the parser defect pinned at
`430_055`, not the permission system doing its job. **A guard whose only live
traffic arrives via another component's failure reads as load-bearing while
being untested.** Its passing tests are all synthetic, and synthetic tests are
written by someone who already believes the mechanism.

## What the wall is actually for

The failure that *does* occur is **drift between the two statements of one
vocabulary.** The register block tells the compiler; a prompt tells the model;
nothing keeps them in step. Give the prompt a fourth verb the block does not
declare and the model emits it immediately and without hesitation — that took
one attempt, where five attempts at defiance produced none.

This inverts the priority. The wall is cheap and stays — a cooperative model is
not the only model, and "it declines today" is a claim about one model on one
day. But the work worth doing is not hardening the wall. It is removing the
duplication that feeds it: a running program cannot ask a scope what events it
has, so the English half of the vocabulary is hand-written and free to rot.
Derive the prompt from the declaration and the wall's real customer disappears.

## The general shape

Before crediting a guard, ask what has actually reached it, not what could. A
guard positioned against an adversary who never arrives is not thereby
worthless — but its value is wherever its real traffic comes from, and that is
usually somewhere nobody designed for.

Related: [[frag-a-handle-count-is-not-a-capability-check]] — the sibling wall in
the same subsystem, failing the opposite way. There a mechanism was credited
with a guarantee it never provided; here a mechanism genuinely provides its
guarantee and is credited for stopping a threat that has never tested it.
