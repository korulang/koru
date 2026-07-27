---
type: belief
id: frag-a-rule-inferred-from-one-failure-is-too-wide
provenance: KORU112 shipped as "effect-branch bodies need `$mod.`" and reddened three green tests; the real rule is narrower and only the corpus knew where the edge was
ts: 2026-07-27
---

# A failing example tells you a rule exists, never how wide it is (belief)

A bug hands you one point in the space. Generalising from it produces the
smallest rule containing that point *and everything you happened to think of* —
which is reliably a superset of the real one, because nothing in the failure
says where to stop.

KORU112 is the worked case. The failing program was an effect-branch proc body
reaching its module by a bare name, and the rule that suggests itself — the one
raylib's own comment states — is "effect-branch bodies need `$mod.`". Built that
way, the wall reddened three tests that had always been correct. The real rule
is a **scope crossing**: a body that splices into ANOTHER module's frame needs
the spelling; one that stays inside its own module does not, and the effect
branch is incidental to both.

The failure could not have told anyone that. Only the cases that were already
green could.

## Green tests are the specification

This inverts the usual reading. A red test says what must change; a **green test
says what must not** — and when a new wall goes in, the green ones are the only
statement of its boundary anyone has. They are not regression insurance in that
moment, they are the spec, and the suite run is how you read it.

Which makes the run non-optional for a new diagnostic in a way it is not for a
fix. A fix has a shape the failing test already describes. A new rule's shape is
unknown until the corpus objects, and the objection is the design information.

## What follows

- **Never land a new diagnostic on the strength of the case that motivated it.**
  Expect the first version to be too wide; the suite is where the edge is found,
  not where the work is confirmed.
- **Read every red it causes as a boundary claim**, not as breakage. Three tests
  saying "I am fine" is the rule telling you its own scope.
- **A rule stated in a comment is also a rule inferred from one failure.**
  raylib's `$mod.` note was written by someone fixing the same crossing, and it
  generalised the same way. Prose in the corpus carries this error as readily as
  a fresh guess does.

## Open

Whether the too-wide version is worth landing *deliberately* — build the broad
rule, run the suite, and read the reds as the specification, rather than trying
to reason the boundary out first. It costs one suite run and buys the edge
exactly. The risk is that a broad rule reddens so much the signal drowns; the
KORU112 case produced three, which was legible. Untested at larger scale.
