---
type: belief
id: frag-template-conditions-refuse-rather-than-default
provenance: found 2026-07-25 probing why an `else`-chain fix to koru_std/control.kz was inert — the guard was populated all along and the `{% if %}` could not read it
ts: 2026-07-25
---

# A metaprogramming layer that cannot evaluate a condition must refuse, not default

The template engine's `{% if %}` took the entire tag body as one variable NAME.
`{% if arm.guard != "" %}` looked up a key literally called `arm.guard != ""`,
found nothing, and a missing key read as false. The guarded branch of that tag
was therefore unreachable — not "usually not taken", *unreachable*, for every
input, forever.

The no-fallbacks law already covers this shape. What makes it worth its own
belief is where it hid and what it did to the people looking for it.

## Why this class of defect resists being found

A dead branch in generated-code machinery has three properties that ordinary
dead code does not:

- **It reads as live.** The branch is right there in the template, with a
  plausible condition above it. Nothing in the source distinguishes it from a
  branch that fires.
- **Fixes applied inside it are inert.** The previous session `else`-chained
  exactly the right branch, rebuilt, saw no change, and concluded — reasonably —
  that the fix must belong somewhere else. An inert correct fix is worse
  evidence than no fix: it reads as *confirmation* that you are in the wrong
  file, and it points the next session away from the answer.
- **Its comment becomes a lie nobody can catch.** The architecture note above
  the template asserted that each arm's guard was exposed and branched on. The
  first half was true and useless; the second described intent. Neither half
  could be checked without emitting a program and reading the output.

The compounding is the point: a silent false in the engine turned into a false
comment in the template, which turned into a false diagnosis in a pin header,
which was the artifact the next session was handed as ground truth.

## The standing requirement

**Conditions in a metaprogramming layer are parsed, and anything the grammar
does not cover is an error naming the grammar.** Not a false, not a skip, not a
best-effort match. The engine's job at the boundary is to refuse.

This is not the same as "support more operators" — the grammar can stay
deliberately small (a bare key, or two operands compared) as long as everything
outside it is loud. A small grammar plus a wall is a design; a small grammar
plus silence is a trapdoor.

## The general tell, for whoever hits this next

When a change to the obviously-correct place has NO effect, the hypothesis to
reach for first is not "wrong place" — it is **"this code does not run."** Probe
before re-deriving: emit the value the condition reads and look at it. One
render answered in seconds what a session of reasoning got backwards.

Related: [[frag-cond-is-exclusive-dispatch]] — the construct this was hiding
under, whose emitted form contradicted its documented one for as long as the
branch stayed dead. [[frag-negative-walls-relitigated-through-prose]] — the same
failure mode one layer up, where prose about a wall outlives the wall's actual
behaviour.
