---
type: belief
id: frag-optimistic-parsing-is-a-decision-deferred-to-a-worse-reader
provenance: `-> name { … }` in a branch arm read as a Source-block invocation because `looksLikeInvocation` was asked first; the unknown-name case was documented as "optimistic parsing — later passes will catch it". They did, as `unknown tor`, pointing at a line that constructs. Fixed 2026-08-08, pinned as 210_190 and 210_209
ts: 2026-08-08
---

# Optimistic parsing defers a decision to a reader with less information

When two grammars claim one spelling, a parser can guess and let a later pass
sort it out. Koru's did, and said so: *"Event not found in registry — might be a
keyword that hasn't been resolved yet. Assume it takes a Source parameter
(optimistic parsing). If it's truly invalid, later passes will catch it."*

They do catch it. **They catch it with less information than the parser had.**
By then the constructor is an invocation, and the only sentence available is
`unknown tor 'verdict' in pipeline` — about a line that constructs nothing of the
kind. The reader is sent to look for a missing declaration that was never
supposed to exist. `-> name { … }` in a branch arm had therefore never worked, on
any event, and the diagnostic pointed away from the cause every time.

The parser is the last place that still knows **where it is**. It knows this text
follows `->`, and the produce position is a different grammar from a pipeline
step: after `->` you name a value, you do not hand something a block of raw text.
Downstream passes see a node, not a position. **Optimism is cheap for whoever
writes the guess and expensive for whoever inherits it**, and the two are never
the same person.

Two things make this shape worth recognising rather than just fixing.

**The comment predicted the failure and shipped anyway.** "Later passes will
catch it" is a claim that the eventual diagnostic will be useful. Nobody tested
that claim; it happened to be false. A note explaining why an ambiguity is safe
to defer should name the sentence the user will get.

**A guess is only safe if the alternative is unreachable, and that is
measurable.** Here it was: across the whole corpus and koru_std, `-> name {`
occurs only as a comprehension row and inside raw MLIR text — nobody has ever
invoked with a Source block in produce position. That measurement took one grep
and would have justified the *opposite* default from the beginning. **Where two
readings collide, count the uses before choosing which one wins by accident.**

Related: [[frag-a-diagnostics-hint-is-a-claim-not-a-tested-path]] — a diagnostic
asserting something nobody exercised. Here the untested assertion is that a
deferred decision produces a legible error.
