---
type: belief
id: frag-a-diagnostics-hint-is-a-claim-not-a-tested-path
provenance: KORU103 rejects `|> finished d` and hints "produce a value with `->` (e.g. `-> finished d`)". Writing exactly that emitted `_ = finished d;`, invalid Zig. Found 2026-08-07 restructuring orisha's server loop; fixed and pinned as 350_017. Second instance 2026-09-28: PARSE006's hint named `fields[0]` for EVERY bare arg — `mm-of(1,2,3)` against `{kind,a,b}` hinted `kind: 2`, `kind: 3`; in-session it fabricated a name the callee never declared. Fixed to name the parameter at the argument's position; pinned 100_087. Evolved 2026-11-11 — KORU092's hint named 2 of 3 legal escapes (omitted the `: name` produce bind); a consumer read the refusal as a missing `|>` idiom and filed a language-gap audit against constructs that already worked
ts: 2026-11-11
---

# A diagnostic's hint is a claim about the language, not a tested path through the compiler

A refusal and its suggested replacement are written at the same moment, by the
same person, out of the same mental model. The refusal gets exercised — every
`MUST_ERROR` test fires the check and pins the message. **The suggestion is
exercised by nobody.** Nothing in the harness compiles the thing the hint tells
you to write, so a hint can name a spelling the emitter has never lowered, and
stay convincing indefinitely.

`KORU103` refuses `|> finished d` in a flow that implements a branchy tor, and
hints: *produce a value with `->` (e.g. `-> finished d`)*. That spelling parses,
passes every check, and reaches the emitter as a plain `.expression` step, where
it lowers to `_ = finished d;` — not valid Zig. The compiler pointed at the one
door that was nailed shut.

This is worse than an absent hint, and worse in a specific way: **it converts a
correct instinct into a wrong one.** The instinct that got me there — "the arm
must produce the tor's branch" — was right. The hint confirmed it, named a
spelling, and I stopped looking. Being told the right *idea* with the wrong
*mechanics* is more expensive than being told nothing, because the confirmation
retires the doubt that would have made me test it.

The general shape: **whenever a diagnostic's hint is followed and the result is
still broken, the bug is TWO bugs.** The missing lowering, and a hint asserting
it exists. Fixing only the first leaves a compiler that lies whenever the
lowering regresses. A hint that names a spelling should have a green test
compiling that spelling — otherwise the hint is prose about the language rather
than a fact about the compiler, and it will drift exactly like any other prose
nobody executes.

Same asymmetry as
[[frag-the-tested-half-of-a-rule-is-the-half-that-is-real]], one level out: there
the untested half sat in a green test's comment, here it sits in a shipped error
message. Both are load-bearing-looking text next to a mechanism that really works,
which is what makes them credible.

Related: [[frag-a-diagnostic-that-names-a-line-must-translate-it]] asks a
diagnostic to be legible; this asks it to be *true*.

The mirror case, 2026-11-11: KORU092's hint taught two escapes — leave the
slot unfilled, or `: _` at the source — and stayed silent on the third that
was already legal: bind the produce at the call (`keep(...): name`). A
consumer wiring `take-calls` drains hit the refusal, could not see the
binding escape in the hint, and filed three "missing language surface"
findings — generic tors, invisible arm bindings, a `tap` combinator — two
of which dissolved under an hour of probes. The hint did not name a wrong
spelling; it named an *incomplete set*, and the omission was load-bearing
in exactly the way the KORU103 case was: it retired the doubt that would
have made the consumer test the escape it was not shown. A hint that
under-specifies the legal surface is the same defect class as one that
asserts a lowering that does not exist — both are prose about the language
where a fact about the compiler was owed.
