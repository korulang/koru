---
type: belief
id: frag-a-red-pin-after-a-tightening-may-be-a-dead-dialect
provenance: session 2026-08-09 (Lars + Claude) — "Let's get Rusty"; the drag-race sieve pin, red 28 days
ts: 2026-08-09
tags: [koru, regression-suite, diagnostics, single-return, migration, benchmarks]
---

When a language tightening lands, the corpus does not migrate itself, and
**nothing re-checks which tests were written in the spelling that just died.**
A test that goes red at `frontend` the day a tightening merges looks exactly
like a compiler regression, and will be read as one — the diagnostic points at
the *program*, and the program has not changed, so the compiler must have.

That inference is wrong in one common case and it is the case a tightening
manufactures: the test was written in a dialect the language deliberately left
behind. The compiler is right and the test is a fossil.

**The discriminator is the corpus, and it is cheap.** Count how many other call
sites spell it the failing way. If the answer is *zero of twelve*, the shape was
never the idiom — it parsed, which is not the same as being the language. Then
reproduce the refusal on a synthetic construct with no stdlib in it: if a plain
two-outcome `tor` refuses the same shape identically, the refusal is a rule, not
a bug in one module's declaration. Both checks cost minutes and they run before
any compiler source is opened.

Worked instance: `2111_prime_sieve_timed_loop`, the deterministic twin of Koru's
Dave Plummer drag-race entry — the program behind our published result against
Rust — sat red at `frontend` from 2026-07-12 to 2026-08-09 with
`KORU010 stray continuation line without Koru construct`. Read as a parser
regression, it produced a plausible mechanism (an inline chain's dedented arms
being orphaned), a plausible patch, and a build. The patch was unnecessary: the
head was inline-binding a **branching** call (`std/field:new(bits: N): f`), a
shape the single-return work correctly closed. Rewritten in the spelling its
green twin `2112` already used, the test passes on an unmodified compiler.

**The prior belief this occludes:** "a red frontend pin on a shape we used to
ship means the compiler lost surface, and the fix lands in `src/`." The
correction is not that compiler defects are rare here — the standing rule that a
`koruc` defect stops everything else is unchanged and right. It is that *the
evidence for a defect is not the redness*; it is the corpus survey and the
synthetic repro, and those come first because they are cheaper than a build.

Open questions:
- Five dead spellings sat in a shipped, reviewed, publicly-submitted artifact
  for four weeks with nothing pointing at them. A tightening knows exactly which
  shape it closed; whether it can leave behind a grep that names the survivors
  is unexplored, and it is the mechanical version of this belief.
- One of the five is worse than a refusal and is why the rot was invisible:
  a branch arm naming a branch a **bare-return** tor does not have
  (`std/time:now(): -> i128` handled as `| t v`) compiles clean and binds the
  value to zero. Silent wrong answers survive migrations that loud refusals do
  not. Tracked separately.
