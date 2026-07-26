---
challenge: docs-without-prose
kind: frame
status: standing
yields: one falsifiable doc claim converted into a test, a pointer, or a rename
family: toolchain
---

# Challenge 003 — Documentation without prose

> Make the documentation *better* without making it *prose*. Prose drifts and contaminates
> (it lied to a contestant and an arbiter in one run, and it lived in 5 places at once). The
> docs still have a job — orient, teach, show what's legal — but every falsifiable claim must
> be carried by a test, not a sentence. Each confirmed improvement drains into a test, a
> pointer, a rename, or a generator change. A flywheel that makes the docs richer while
> structurally unable to drift.

A standing **generative frame**, not a backlog.

---

## The law — the three-way split (this is the whole challenge)

Documentation splits by what is *falsifiable against the compiler*. Only one slice may be prose:

1. **WHAT is legal / what something does** → **never prose.** The test IS the doc: a curated
   regression test, a generated tour (`docs/by-example/*`), a well-named test directory. If you
   would write a sentence asserting behavior, you instead point at the test that *proves* it.
2. **HOW to find it** → **pointers, not restatements.** "`tests/regression/020_011`" cannot
   drift; "the parser does X" does. A path is safe; a paraphrase is poison.
3. **WHY — intent, design rationale** → the **only** legitimate prose, because it is not
   falsifiable against the compiler. Minimal, and *marked* as intent, never as law.

**THE GOVERNING RULE (binding on everyone): no proposed documentation improvement may add a
falsifiable prose claim.** Only a test, a pointer, a rename, a generator change, or marked
intent. A proposal that adds a sentence asserting compiler behavior is malformed by
construction — that is the exact cancer this challenge exists to prevent.

---

## The faucet — how contestants generate signal

1. **Drifting/falsifiable prose (primary).** Hunt `CLAUDE.md`, `AGENTS.md`, the skills, and any
   doc for sentences that make a falsifiable claim about what Koru does. For each: the claim, a
   koruc run that confirms or refutes it, and the **non-prose replacement** (the test that
   carries it, or kill it if a test already does).
2. **Missing where a tour would teach.** Find a real shape a newcomer needs that has no curated
   test/tour. Propose the test to add (or the existing test to surface), NOT a paragraph.
3. **Structure that doesn't self-document.** Find badly-named or badly-organized tests where a
   rename/reorg would make the structure teach on its own. Propose the rename.

---

## ⚖️ THE HARD STANCE — qualified guess, never a verdict; and never add prose

Same asymmetric hierarchy as the other challenges: a doc claim diverging from koruc has two
readings — **(A)** the doc is wrong (drift), **(B)** your reading of the doc/compiler is wrong.
Make a **qualified guess** (A / B / unsettled) with `confidence` defined by evidence (`grounded`
= you ran koruc / cite a passing test; `inferred` = reasoning; `unsettled` = no prior art). You
write both readings in full, you never edit a tracked file, the arbiters rule.

**And the extra rule unique to this challenge:** your `proposed_action` is itself checked against
the governing rule. If your proposed "improvement" adds a falsifiable prose claim, it is rejected
on sight — propose the test/pointer/rename/intent instead.

---

## For contestants (the brief, sealed)

Dropped into `/Users/larsde/src/koru`. **Read the repo-root standards first** (`CLAUDE.md`,
`AGENTS.md`) — and as you read, you are hunting *them* for falsifiable prose. Build koruc
(`zig build`) so you can verify claims against it.

Return 4–8 **findings**. For each: `doc_location` (file:line), `finding_class`
(falsifiable-prose / missing-tour / bad-structure), `the_claim_or_gap`, `evidence` (the koruc
run or the test that grounds it), `reading_A_doc_wrong`, `reading_B_your_reading_wrong`,
`qualified_guess` {lean, confidence, prior_art}, `proposed_action` (a test to add, a pointer, a
rename, a kill, or marked-intent — and it MUST add zero falsifiable prose), `adds_falsifiable_prose`
(must be `false`), `severity`.

Do NOT edit tracked files. Propose only. Everything is a hypothesis grounded in a real run.

---

## For arbiters (Lars + Claude)

Per finding: rule which side moves, verify against koruc yourself, then drain the real ones —
kill the drifting prose, add the curated test/tour, do the rename, or wire the generator. Reject
any proposal that smuggles in a falsifiable claim. **Never** reconcile reality to the prose (the
compiler wins); never let a sealed contestant settle the design question.

## Pass / value contract

A run earns its keep when it produces **≥1 documentation improvement the arbiters merge that adds
ZERO falsifiable prose** — a killed claim, an added test/tour, a rename, or a marked-intent note.
That zero is the whole point.
