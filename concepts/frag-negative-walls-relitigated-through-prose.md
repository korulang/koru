---
type: belief
id: frag-negative-walls-relitigated-through-prose
provenance: 2026-07-24, after the koru-toolchain skill was found describing the 320_047 MUST_FAIL wall as a "known gap"
ts: 2026-07-24
---

# A `MUST_FAIL` wall cannot defend itself against prose that calls it a gap (belief)

A negative test is the strongest thing the corpus can say: *this form is
rejected, and rejection is correct.* But the wall is mute about how it is
**described elsewhere**. Any doc, skill, or memory that re-narrates it as "a known
gap that doesn't lower yet" silently converts a settled rejection back into a
roadmap item — and the test goes on passing the whole time, so nothing in the
suite ever registers the inversion. **The suite cannot detect a document lying
about it.** That is the gap this belief exists to name.

## The worked instance

`320_047` pins that `~` inside a Koru flow is illegal: `~decide = ~if(cond)` puts
a second `~` on the RHS of a flow that is already in Koru. Its `input.kz` opens
with "NEGATIVE TEST … It is NOT a feature awaiting a fix," and records that two
ADD loops on 2026-05-31 mistook the rejection for a bug — the first pinning it
"to fix later" (`b5a4d4de`), the second teaching `parser.zig` to **strip the
leading `~`** so the illegal code would compile (`2e986a27`, reverted
`b26b8d1b`). The test was then hardened with that history written into it
precisely so it would not happen again.

It happened again anyway, one level up. The `koru-toolchain` skill — the document
agents are told to read *before* reading any code — described the same form as a
**"Known gap: … does NOT lower yet … Pinned in `320_047`."** Every agent that
oriented through the skill received the repudiated premise as current fact, from
the artifact with the most authority and the least scrutiny, while the wall stood
green and silent one directory away. The skill even contradicted its own next
bullet ("`~` is parser mode, never written inside a flow") without anyone
noticing, because nothing cross-checks a doc against a pin.

Found 2026-07-24 by Lars, reading the line cold: *"this has NEVER been valid
syntax."*

## Why prose is the vulnerable surface, structurally

The test suite is continuously executed; drift in it is caught within one run.
Docs and skills are executed **by agents, silently, as premise** — a stale claim
there has no failing state, produces no red, and is laundered into authority by
being the designated starting point. The orientation layer is therefore the
highest-leverage place in the repo for a lie to live, and the only layer with no
automatic verdict on it.

Two consequences worth holding:

- **A doc that references a test must not restate the test's verdict.** Name the
  pin and let it own its own red/green — `320_047` says what it says. The moment
  prose paraphrases a wall's meaning, it has taken on a maintenance obligation
  nothing enforces. (This is the orientation-layer instance of the standing rule
  against state-prose in test comments.)
- **Softening a suspicious claim is worse than deleting it.** In this same
  session the line was first *neutralized* ("the harness owns whether it lowers
  today") rather than checked against `320_047` — which preserved the false frame
  while removing the tell that would have exposed it. When a doc claim smells
  stale, the move is to open the artifact it cites, not to launder the sentence.

## The detector

For any doc sentence of the form *"X is a known gap / doesn't work yet / awaits a
fix,"* open the pin it names before believing or editing it. If the pin is
`MUST_FAIL`, the sentence is not stale — it is **inverted**, and the fix is
deletion plus a note that the wall is deliberate.
