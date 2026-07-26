---
type: belief
id: frag-a-corpus-exercises-its-authors-idioms
provenance: binding libcurl's multi interface broke the pipeline surface four ways in one sitting, on the oldest and most-exercised construct in the language
ts: 2026-07-27
---

# A test corpus exercises the idioms of whoever wrote it (belief)

Coverage is usually read as a property of the *code* — which paths run, which
branches are taken. The more useful reading is that a corpus records **how its
authors write**, and is silent about every other way the same construct can be
spelled.

Koru's pipeline surface is the oldest and most exercised thing in the language.
Writing the first program that chains a real library through several steps broke
it four ways in one sitting: `//` inside a mid-chain string taken as a comment, a
multi-line chain swallowing the arms that follow it, a chain step's result not
threading to the next, and a re-bind refused by the host compiler rather than
this one.

None of those are exotic. They are what a *consumer* writes on day one: a URL, a
pipeline long enough to want line breaks, a handle carried from step to step. The
corpus is full of chains — with numeric payloads, on single lines, at flow heads,
because that is what a compiler author writes when demonstrating that chaining
works.

## Why this is not just "write more tests"

The gap is invisible from inside. Every one of those shapes looks obviously
covered when you already know the idiom the tests use; the missing spellings are
missing precisely because nobody thought of them as spellings. You cannot review
your way to them — the reviewer shares the idiom.

What *does* find them is a consumer with their own habits, which is the real
argument for application clusters as instruments
(`frag-milestone-suites-are-instruments`). They do not find bugs because apps are
complicated. They find bugs because the app author writes differently from the
compiler author, and difference is the entire mechanism.

An app that merely re-plays the corpus's idioms would find nothing.

## What follows

- **Prefer a consumer's spelling to a minimal one** when adding coverage to a
  well-worn construct. The minimal spelling is almost certainly already there.
- **A construct's bug density is unrelated to its age.** Most-exercised and
  best-tested are different properties, and the first is routinely mistaken for
  the second.
- **When an app breaks something old, expect a cluster, not an instance.** Four
  faults in one sitting on one construct is the signature of an unexercised
  idiom rather than four coincidences.

## Open

Whether this can be attacked directly — generating spelling variants of existing
fixtures (line breaks moved, literals substituted, bindings renamed) and checking
the suite still passes. It would have caught at least two of the four
mechanically. The risk is a pile of generated tests nobody can read, which is its
own kind of rot; a generator that produces *failures* to triage, rather than
tests to keep, may be the better shape.
