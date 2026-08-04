---
type: belief
id: frag-tests-and-compiler-coevolve
provenance: migrated from koru/CLAUDE.md 2026-07-24
ts: 2026-07-24
---

# Tests and compiler co-evolve; neither is authoritative, and triage is design work (belief)

Koru has no formal spec. The compiler is being designed; the test suite is being
designed; they move together. The language emerges from the conversation between
them — not from one being the source of truth and the other following.

Three consequences:

- **Tests are often wrong.** A test encodes an intent from when it was written.
  That intent may not match where the language is now going. Not a defect —
  information about a design decision nobody has re-examined.
- **The compiler is often wrong.** It encodes rules that may be too strict, too
  lax, or carving the syntax up wrongly. Also information.
- **Nobody is "wrong."** Not the test author, not the commit, not the compiler
  change. The frame *"this regression was caused by commit X"* is imported from
  production and does not fit. Every failing test is a place where two pieces of
  the building haven't been lined up yet.

## Triage is design work

When a test fails, the question is never whose fault it is. It is one of:

1. **What is the test trying to say, and does the language still want to say
   that?** If yes, the compiler needs to support it. If no, the test changes or
   goes.
2. **What did the compiler do, and is that what the language should do?** If yes,
   the test encodes stale intent. If no, the compiler changes.
3. **Are both encoding something the language has moved past?** Then both change
   in one commit.

In practice: don't lead triage with "which commit broke this." Don't apologize for
or assign blame to commits, including your own — commits are moves in a design
conversation, not promises being broken. Don't preserve a test merely because it
once passed, or a compiler rule merely because it was added recently. When the two
disagree, the question is "what does the language want?", never "which one is
correct?"

Failure is valuable: it surfaces evidence about a direction the language might
want, or evidence that a direction isn't viable. **The expensive thing is failure
that teaches nothing** — not failure itself.

## Why this needs recording — code cannot hold it

The suite records *what* passes and fails; it is structurally silent on the
epistemic status of either side. Nothing in a red test says "this red may mean the
test is stale rather than the compiler broken." Without this belief, a session
defaults to the production frame it was trained on — tests as contract, red as
someone's fault, git blame as triage — and that frame produces exactly the wrong
first move: preserving a stale test by contorting the compiler to satisfy it.

This is the epistemic half of [[frag-greenfield-breaking-is-the-job]]: that
fragment says breaking is allowed, this one says neither side gets to claim it was
right all along.
