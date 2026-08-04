---
type: belief
id: frag-a-recorded-impossibility-outlives-its-truth
provenance: 2026-08-04 — porting archetype_churn_world to Koru; the ECS harness's fanout note had carried "not spellable and no amount of cleverness makes it so" about an access that composes from two features already shipped
ts: 2026-08-04
---

# A recorded impossibility outlives its truth, because nothing retests a comment (belief)

A capability claim gets retested constantly: it has a pin, and the pin runs. An
**impossibility** claim is written in prose, next to the workaround it justifies,
and then nothing ever asks it again. The corpus cannot hold it — there is no
failing test for "this cannot be written", and the workaround's own green test
certifies the workaround, never the premise.

So the two halves of the record age at completely different rates. Every "we can
do X" in this repo is either true or loudly broken. Every "we cannot do X" is
whatever was true on the day someone gave up, preserved verbatim, and reported to
the next reader with exactly the same confidence as the tested half.

## Composition grants capabilities silently, which is why the premise rots

`frag-composition-is-korus-bug-surface` says Koru's bugs live in combinations
because features share machinery. The same mechanism runs in the other direction
and is easier to miss: **a combination can become expressible without anyone
implementing it, or noticing.** Two features land for two unrelated reasons, and
their composition is a third feature that has no author, no commit, no pin, and
no announcement.

Nobody is wrong at any step. The person who wrote the impossibility was right at
the time. The two people who shipped the halves were each solving their own
problem and had no reason to revisit a comment in a benchmark port. The claim
simply outlived the conditions that made it true, and prose has no mechanism for
noticing that.

## The tell is the ABSOLUTE tone, and it is the opposite of what it looks like

The sentence that stood in front of this one was *"and no amount of cleverness
makes it so"*. That reads as the most reliable kind of claim — someone thought
hard and closed the question. It is the least reliable kind, and the strength of
the phrasing is itself the signal, for two reasons:

- **It forecloses.** A hedged note invites a retry; a closed one instructs the
  next reader not to bother, and they will not. The more emphatic the closure,
  the longer the reprieve from ever being checked.
- **Nobody writes it calmly.** That register comes from having just failed at
  something, which is precisely the moment with the *least* perspective on what
  a different combination of features might do later.

So: an impossibility claim's confidence is not evidence about the world. It is
evidence about the author's state when they stopped.

## What follows

- **Treat every "cannot" in prose as UNDATED and untested, whatever its tone.**
  A capability claim without a pin is a rumour; an impossibility claim never had
  one available. The cost of retesting is usually one small probe — here, a
  dozen lines and one compile.
- **Probe the composition before believing the component.** The question is not
  "does the store address rows by position" (it does not) but "is there anything
  else in reach that is positionally addressed" (there was). An impossibility
  stated about one module is only ever a claim about that module.
- **When a "cannot" turns out to be false, correct the sentence in place.** Two
  contradictory claims in one file is worse than the original error: the reader
  cannot tell which is current, and the stale one is usually the one nearer the
  code they are reading. Say what it used to claim and why that was wrong, so the
  next person inherits the correction rather than rediscovering the confusion.
- **The workaround is the artefact to distrust, not the comment.** The comment is
  merely wrong; the workaround is a deliberate divergence still shaping behaviour
  and still being measured. When the premise falls, the divergence becomes a
  choice — and it has to be re-argued as one, not left standing on a dead reason.

## Open

Whether this is worth a mechanism rather than a habit. A grep for absolute
closure language ("not possible", "cannot be", "no amount of") would enumerate
the repo's untested impossibility claims cheaply, and each one is a candidate
probe. That is an appealing wall and an unproven one: the cost is a list nobody
works through, and the same claim written without a flagged phrase escapes it
entirely — the usual weakness of a lexical wall guarding a semantic property.
