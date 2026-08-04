---
type: belief
id: frag-the-boundary-of-the-possible-has-no-verdict
provenance: merged 2026-08-04 from frag-negative-walls-relitigated-through-prose (2026-07-24, a MUST_FAIL wall re-narrated as a "known gap" by the orientation skill) and frag-a-recorded-impossibility-outlives-its-truth (2026-08-04, "not spellable and no amount of cleverness makes it so" about an access that composed from two shipped features)
ts: 2026-08-04
tags: [epistemics, orientation, prose, walls]
---

# A claim about what CANNOT be done has no verdict attached, so it drifts both ways (belief)

Capability claims are continuously audited: each has a pin, and the pin runs. A
claim about the **boundary** — this is rejected, that cannot be written — lives
only in prose, and prose has no red state. The corpus cannot hold it. There is no
failing test for "this is impossible", and the workaround's own green test
certifies the workaround while never touching the premise that justified it.

So the two halves of the record age at completely different rates. Every "we can
do X" here is either true or loudly broken. Every "we cannot do X" is whatever
was true the day someone stopped, preserved verbatim, and handed to the next
reader with exactly the authority of the tested half.

**The suite is structurally blind to a document lying about the boundary.** That
is the whole of it; the two directions below are the same absence seen twice.

## Direction one — a settled rejection re-narrated as a gap

`320_047` pins that `~` inside a Koru flow is illegal. Its `input.kz` opens
"NEGATIVE TEST … It is NOT a feature awaiting a fix," and records that two ADD
loops on 2026-05-31 mistook the rejection for a bug — the first pinning it "to
fix later", the second teaching `parser.zig` to strip the leading `~` so the
illegal code would compile, then reverted. The test was hardened with that
history written into it precisely so it could not happen again.

It happened again one level up. The `koru-toolchain` skill — the document agents
are told to read *before* any code — described the same form as a "Known gap: …
does NOT lower yet … Pinned in `320_047`." Every agent orienting through the
skill received a repudiated premise as current fact, from the artifact with the
most authority and the least scrutiny, while the wall stood green one directory
away. The skill contradicted its own next bullet without anyone noticing, because
nothing cross-checks a doc against a pin. Found 2026-07-24 by Lars, reading it
cold: *"this has NEVER been valid syntax."*

## Direction two — a real limit that expired, preserved as permanent

The ECS harness's `fanout` port carried, for months: *"a cell names a row by
handle, never by position, so that access is not spellable and no amount of
cleverness makes it so."* It justified a deliberate divergence from both anchor
implementations, and that divergence was measured and published.

It was false. A `std/grid` is positionally addressed, so a grid whose cells hold
handles is exactly the missing `Vec<Entity>`, and `agents[xref[i].h].hp` lowers.
**Nothing had to be built.** Two features shipped for unrelated reasons — a
write's row address carrying a nested read, and a positionally-addressed grid —
composed into a third that had no author, no commit, no pin, and no
announcement. Nobody was wrong at any step; the claim simply outlived the
conditions that made it true, and prose cannot notice that.

This is the mirror of `frag-composition-is-korus-bug-surface`. That belief says
Koru's bugs live in combinations because features share machinery. The same
mechanism runs the other way and is easier to miss: **composition grants
capabilities silently.** A bug announces itself eventually; a granted capability
announces nothing, and the old prose keeps refusing on its behalf.

## The tell is ABSOLUTE tone, and it inverts what it looks like

*"No amount of cleverness makes it so."* That reads as the most reliable kind of
claim — someone thought hard and closed the question. It is the least reliable,
and the strength of the phrasing is itself the signal:

- **It forecloses.** A hedged note invites a retry; a closed one instructs the
  next reader not to bother, and they will not. The more emphatic the closure,
  the longer the reprieve from ever being checked.
- **Nobody writes it calmly.** That register comes from having just failed at
  something — precisely the moment with the least perspective on what a different
  combination of features might do later.

An impossibility claim's confidence is not evidence about the world. It is
evidence about the author's state when they stopped.

## What follows

- **Treat every "cannot" in prose as UNDATED and untested, whatever its tone.**
  A capability claim without a pin is a rumour; an impossibility claim never had
  one available. Retesting is usually one small probe — a dozen lines, one
  compile.
- **A doc that references a test must not restate the test's verdict.** Name the
  pin and let it own its own red and green. The moment prose paraphrases a wall's
  meaning it takes on a maintenance obligation nothing enforces. (The
  orientation-layer instance of the standing rule against state-prose in test
  comments.)
- **Probe the COMPOSITION before believing the component.** The question was
  never "does the store address rows by position" (it does not) but "is anything
  else in reach positionally addressed" (there was). An impossibility stated
  about one module is only ever a claim about that module.
- **Softening a suspicious claim is worse than deleting it.** In the `320_047`
  session the line was first *neutralised* ("the harness owns whether it lowers
  today") rather than checked against the pin — preserving the false frame while
  removing the tell that would have exposed it. When a claim smells stale, open
  the artifact it cites; do not launder the sentence.
- **Correct in place, and say what it used to claim.** Two contradictory claims
  in one file is worse than the original error: the reader cannot tell which is
  current, and the stale one is usually nearer the code they are reading.
- **The workaround is the artefact to distrust, not the comment.** The comment is
  merely wrong; the workaround is a live divergence still shaping behaviour and
  still being measured. When the premise falls, that divergence becomes a
  *choice*, and it has to be re-argued as one rather than left standing on a dead
  reason.

## The detector

For any sentence of the form *"X is a known gap / doesn't work yet / awaits a
fix,"* open the pin it names before believing or editing it. If the pin is
`MUST_ERROR`, the sentence is not stale — it is **inverted**, and the fix is
deletion plus a note that the wall is deliberate.

For any sentence of the form *"X cannot be expressed / is not spellable,"* the
pin does not exist, so there is nothing to open. Write the probe instead.

## Open

Whether this is worth a mechanism rather than a habit. A grep for absolute
closure language ("not possible", "cannot be", "no amount of") would enumerate
the repo's untested boundary claims cheaply, and each is a candidate probe. That
is an appealing wall and an unproven one: the cost is a list nobody works
through, and the same claim written without a flagged phrase escapes it entirely
— the usual weakness of a lexical wall guarding a semantic property.
