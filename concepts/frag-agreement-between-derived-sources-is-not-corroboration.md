---
type: belief
id: frag-agreement-between-derived-sources-is-not-corroboration
provenance: D7, 2026-07-31 — three sources agreed that row identity was an open question gated on key-marking; all three were downstream of DESIGN.md, which had ruled it weeks earlier and which I never opened
ts: 2026-07-31
---

# Three documents agreeing is one source repeated, if they share an origin (belief)

I researched row identity across three places and they told the same story: it is
an open design question, and the gate is *how a key gets marked at `new`*.

- `OUTSTANDING_DESIGN_DECISIONS.md`'s D7 said so directly.
- The store-identity baton in memory said so, with the mechanism spiked and the
  hole named as "the declaration surface".
- The prose transcript of the session where it was discussed said so, in the
  participants' own words.

I reported it to Lars as three open sub-questions, and published it in an
artifact. **It was wrong.** `690_STORE/DESIGN.md` ruling **O10** had settled it:
identity is a *memory contract* — handles stable across other rows' removal, a
generational check per access as the safety floor, mechanism left to the planner.
Not a key. No user surface at all.

All three of my sources were **downstream of that document**. Their agreement was
not three witnesses; it was one unread ruling, paraphrased three times, drifting
a little further each time until "the mechanism is the planner's" had become "the
user must declare a key."

## Why the agreement felt like verification

Independent confirmation is the strongest everyday evidence there is, and
checking three places *feels* like exactly that. The failure is that
independence was assumed from **format** — a design doc, a memory file, a
conversation log are three different kinds of artifact, so they read as three
different vantage points.

They are not vantage points. They are **generations**. A baton summarises a
session; a session was reasoning about a document; the document is the source.
Reading down a lineage and mistaking it for reading across one is the whole
mistake, and nothing in the artifacts marks which direction you are travelling.

## The rule

**Before treating agreement as corroboration, ask what each source is derived
from.** Sources that share an ancestor corroborate the *ancestor's* reading, not
the fact.

And the practical form, which is cheaper than it sounds: **find the most
upstream artifact and open it.** For anything in the store, that is
`690_STORE/DESIGN.md` — it carries the ruled text, and the batons, decisions doc
and transcripts are all commentary on it. One read of the source would have
replaced three reads of its descendants and been right.

⚠️ The tell is available in advance: if every source is *narrative* — telling you
what was decided — and none is *normative* — the decision itself — you have not
reached the origin yet.

## Open

- No inventory exists of which documents are normative and which are derived.
  `DESIGN.md` under a test category is normative; `OUTSTANDING_DESIGN_DECISIONS.md`
  turns out to be derived, which is not obvious from its name and is arguably a
  naming problem rather than a research one.
- Related but distinct: [[frag-compliance-is-counted-with-the-enforcers-predicate]]
  is about measuring against the enforcer rather than the description. This is the
  same instinct one level up — read the ruling rather than the account of it — and
  the two together suggest a single rule: *go to the thing that is executed or
  decided, never to the thing that describes it.*
