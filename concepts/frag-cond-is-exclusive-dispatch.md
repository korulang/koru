---
type: belief
id: frag-cond-is-exclusive-dispatch
provenance: ruled by Lars 2026-07-25 on the 320_138 fork ("yes, I think `cond` is a named dispatch"); repudiates the prior reading that cond's template already dispatched first-match
ts: 2026-07-25
---

# `cond` is named dispatch — exclusive, and exclusivity has to be structural

**The ruling (Lars, 2026-07-25): `cond` is a named dispatch.** The arm whose
guard matches runs, and no other arm does. This had never been stated outright,
and it was a live fork: the alternative reading — arms as independent guarded
statements, evaluated in sequence — is coherent Zig and would have made the
pin wrong instead of the compiler.

What settles it is the vocabulary the construct already carries. `| c _` is only
meaningful as an *else*; a fall-through reading makes the catch-all fire on every
call alongside whichever arm matched. And the three exhaustiveness rules around
it are all first-match-shaped: KORU050/051 require the guardless arm to exist,
KORU053 requires it to be last. Those rules describe a cascade or they describe
nothing.

## The part that is not derivable from the tests

Exclusivity is a property of the LOWERING, not of the arms. The pin (`320_138`)
can only distinguish the two readings through a side effect — two arms toggling
one store field back and forth — because a value arm returns and so stops the
fall-through by accident, whatever shape it was emitted in. That accident is
what let a fall-through lowering look correct for as long as it did: every value
cond in the corpus was green, and the effect conds nobody had written yet were
the only ones that could tell.

So the standing requirement is stronger than "320_138 must stay green": **the
emitted form must be one in which a later guard CANNOT be evaluated against
state an earlier arm wrote.** An `if / else if / else` cascade has that property
structurally. N sibling blocks do not, and no amount of care inside the blocks
gives it back. A future rewrite that keeps the pin green by making arm bodies
diverge again would be re-introducing the accident, not preserving the ruling.

That is also why the arm binders are hoisted ahead of the cascade rather than
bound per arm: a guard sitting in condition position must already see the name
its arm binds. The pressure runs the other way from how it looks — per-arm
binding is what forced the sibling-block shape, and the sibling-block shape is
what lost exclusivity.

## Repudiated

We believed cond's template already emitted a first-match chain, and that its
`{% if arm.guard != "" %}` branch was live but reached only for value arms. It
had never rendered, for any arm, in any program: the template engine could not
evaluate the condition and silently read it as false. See
[[frag-template-conditions-refuse-rather-than-default]] — the wall built there
is what stops a construct's *stated* dispatch discipline from diverging from its
emitted one without anybody being told.

Related: [[frag-effect-continuation-marker-kinds]] — the other place where two
surface forms that read as interchangeable turned out to be separate kinds, and
the fix was a wall rather than a convention.
