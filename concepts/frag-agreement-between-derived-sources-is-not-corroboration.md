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

## The same error against a PIPELINE, 2026-08-06 — and the closing rule caught it

The rule at the end of the Open section — *go to the thing that is executed,
never to the thing that describes it* — was written about documents. It applies
unchanged to code, and I broke it the same day I quoted it.

Two regression tests were parked with `TODO` markers, which moves them out of the
pass column. The question was whether the public board needed a full re-run to
reflect that. The ceremony notes say, accurately, that the site's `status.json` is
regenerated from the **live test markers on disk**, so tests changed since the
snapshot are picked up at publish time. I read that, concluded the published board
would self-correct, published without re-measuring, and told Lars so.

It was half true, which is the dangerous amount. `status.json` IS marker-derived
and did update. But the number a reader actually sees — the `Passing Features`
headline — is **snapshot**-derived, tied to `test-results/latest.json` and its git
SHA. So the per-test list said one thing and the headline said another, and the
headline is the artifact. The site published `1357` while the markers said `1355`.

Every signal reported success: both pushes landed, the deployment showed Ready,
the edge returned `x-vercel-cache: MISS` with `age: 0`, and the regenerated
`status.json` on `origin/main` genuinely contained the new count. Nothing in the
pipeline was broken. The stale number was correct output from a stage I had not
realised was in the path.

What generalises, and it is sharper than the document version:

- **One artifact can have two provenances, and a true statement about one does not
  constrain the other.** "Regenerated from markers" was a fact about a file, and I
  spent it as a fact about a page. When a surface has a summary and a detail view,
  assume they are fed differently until you have read the generator, because the
  summary is the part that gets quoted and the detail is the part the docs
  describe.
- **The prose was not wrong — my inference from it was.** That makes this worse
  than a stale document, because there is nothing to correct upstream. The defect
  was reading a description where the generator was one grep away.
- **A count check is ambiguous in BOTH directions.** The ceremony notes already
  warn that polling a pass count cannot detect a failed deploy when the count did
  not move. The mirror bit me: the count DID move in my data and not on the page,
  so ten minutes of polling read as a broken deploy when the deploy was perfect.
  Poll the thing that is unique per publish — the SHA — even when a count looks
  like it would discriminate.

Residue: the board was re-measured and the headline now matches the markers. The
durable part is that "derived from X" is a claim about one file, and the honest
follow-up question is always *which file does the reader see?*
