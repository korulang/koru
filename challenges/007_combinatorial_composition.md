---
challenge: combinatorial-composition
kind: frame
status: standing
yields: one uncovered feature combination, pinned green or as a MUST_FAIL
family: toolchain
---

# Challenge 007 — Combinatorial Composition (does the syntax still compose?)

> You ARE the contestant, not the assistant. Pick ONE **combination** of language
> features that the corpus does **not** already cover — a pair or triple of
> constructs nested/chained/threaded together — write the smallest Koru program
> that composes them, state what it should do and **why** (grounded in the rules
> the components already obey), then run `koruc` and see whether the compiler
> treats the composition **coherently**. Do **not** ask which combination to pick —
> read the corpus, find an uncovered one, name it, ship. Your choice of combination
> and your grounded prediction ARE the contribution; Lars judges *after* you ship,
> by re-running. Asking first negates the design.

This is a standing **generative frame**, not a backlog. There is no list of
combinations to work down; each run re-derives "which composition is uncovered"
from the live corpus and adds one. Every run yields a **catalog entry either way**:
a composition that works becomes a **new green combinatorial test** (the interaction
is now locked against regression); a composition that diverges becomes a **red pin**
that names a compiler gap in its own terms. Both are releasable by construction. The
valuable output persists in the regression suite, not a to-do.

---

## Why Koru needs this challenge and C / Python / Rust do not

In a conventional language, features are **orthogonal**. A `for` loop, a `try`, and
a struct literal each have their own parser production and their own isolated
type-checking codepath. Nesting them is boring *because there is no shared invariant
to break* — the combination is free, and nobody writes a "combine your syntax"
fuzzer for C because it would find nothing.

Koru's thesis is **control flow into the type system**. Effect branches, obligations,
phantom `<state>`, captures, pipelines, bare-return, subflows — these are **not**
orthogonal. They all thread through the *same* shared analysis machinery: the flow
checker's model of what threads through a point, the phantom checker's namespace
tracking, the metacircular pipeline. So composing feature A with feature B exercises
an interaction *inside* that shared machinery that neither A-alone nor B-alone ever
touches — and when the machinery has been implemented twice and drifted, the
composition is exactly where the drift becomes visible.

The evidence is already in the tree:

- **`670_NESTING_SWEEP`** is a hand-authored 5×6 combinatorial grid, and its one red
  (`670_023_readlines_under_effect`) is a *composition* failure — neither component
  is broken alone.
- **`220_017_effect_branch_multiline_chain`** pins a composition bug and names its
  root: SHAPE002 is implemented *independently* in `shape_checker.zig:1963` **and**
  `flow_checker.zig:1169`, and the `!`-branch multi-line path diverged from the
  `=`-subflow path. The `=` form of the exact same shape compiles; the `!` form does
  not.
- The memory of this repo is a list of composition gaps: *obligation-through-records,
  store composition under phantom namespacing, effect-branch multi-line chain,
  typed-value channel.* Each was found by hand, one at a time. This challenge farms
  that class on purpose.

---

## The oracle — COMPOSITIONALITY, and the sibling-form seam

"Does it still work" needs a sharper definition than "it compiles." The invariant
this challenge tests is **compositionality**:

> If construct **A** is legal in a context and construct **B** is legal in that
> context, then **A composed with B is legal and means the obvious thing** — unless
> a *stated rule* forbids that composition, in which case the rejection must carry a
> **correct, specific, koru-level diagnostic** naming why.

A run produces a **finding** when reality diverges from that invariant:

- **False reject** — the composition is rejected but no rule forbids it. → a pin that
  names the checker gap (as `220_017` names SHAPE002-implemented-twice).
- **False accept** — the composition is accepted but miscompiles or produces the
  wrong runtime answer (or a host-level Zig leak instead of a koru result).
- **Bad diagnostic** — the rejection is *correct* but the message is wrong: unlocated,
  blaming the wrong span, advising a fix that doesn't work (`220_017`'s "indent it
  further" does not fix it), or leaking generated Zig (`use of undeclared identifier`).
- **Sibling-form divergence — the sharpest finding.** Many constructs have two surface
  forms that must mean the same thing: `!` effect-branch vs `=` subflow; inline `|>`
  chain vs multi-line `|>` chain; `-> T` bare-return vs `: bind`. If form **A** under
  composition **X** is legal, its sibling form **B** under the same **X** must behave
  identically or fail with a correct diagnostic. Divergence here is the fingerprint of
  a shared checker implemented twice and drifted — the richest seam in the compiler.
  Prefer probing it.

A composition that **matches** the invariant is **not** a null result here — unlike a
pure fuzzer, a confirmed working composition is a **deliverable**: it becomes a new
green combinatorial test locking the interaction in. Both outcomes append to the
catalog. (Oracle set at creation, 2026-07-20 — slow-clock; change it here
deliberately if ever.)

---

## The axes — read the corpus for what exists, never invent

The features you compose and the contexts you nest them under are **whatever the
corpus proves exist** — do not synthesize a construct from analogy or first
principles (that's the repo's cardinal rule; a probe built on invented syntax is
noise, not signal). The `670_NESTING_SWEEP` grid names the starting axes explicitly:

- **Constructs** (the thing you place): capture, `read-lines`, `! each *` / for-each,
  if-cond branch, string branch — and beyond the current grid: obligations, phantom
  `<state>`, pipelines `|>`, bare-return `->`, subflows `=`, `std/store`
  (new/watch/stored), records, event globbing.
- **Contexts** (what you place it under): flow-head, scalar, obligation, effect,
  for-each, capture.
- **Surface-form siblings** (the seam above): `!`↔`=`, inline↔multi-line,
  `-> T`↔`: bind`.

Ground every construct you use in a **passing** regression test (cite `file:line`).
The novelty you contribute is the *combination*, not the pieces — so the pieces must
be real.

---

## The variance rule — variance lives in WHICH COMBINATION, never in the components

Variance across contestants is the metric, and it lives in **which uncovered
combination you probe** and **which direction you nest / chain / thread it**. Two
contestants picking the same pair is wasted breadth; the whole value is reach across
the `features²` (and `features³`) space.

Variance does **NOT** live in inventing new constructs or bending what a component
means. Each component behaves exactly as its own passing tests say it does. "Which
combination, nested which way" is the freedom; "each piece is the real, corpus-proven
piece" is the law.

---

## Self-grounding — map the coverage before you pick

Before building, establish what's already covered so your pick is genuinely new:

1. Read `670_NESTING_SWEEP/` — the existing grid of `<construct>_under_<context>`.
2. Grep the suite for co-occurrence of your candidate pair (e.g. a test that has both
   an obligation *and* a record, or both a `|>` chain *and* an effect branch).
3. If the pair already has a green test that composes them the way you intend, it's
   covered — pick a different pair, a third feature, or a different nesting direction.

This step is the Scout's gap-finding, internalized: the challenge is aware of its own
prior output and diverges from it, every replay.

---

## For contestants (the brief, sealed)

You are dropped into the koru repo. **Read the repo-root standards first** —
`CLAUDE.md` and `AGENTS.md` — they bind. Build koru once (`zig build`) so
`./zig-out/bin/koruc` is fresh.

1. **Self-ground against the coverage** (section above). Pick ONE combination the
   corpus does **not** cover. Name it in one line: *"`<A>` under/through/chained-with
   `<B>`."*
2. **Ground each component** in a passing test (`file:line`) — the pieces are real,
   only the combination is new.
3. **Write the smallest program** that composes them, and **state the prediction +
   WHY**: should this compile-and-run (and print what)? should it be rejected (with
   which specific diagnostic)? Ground the WHY in the compositionality invariant and
   the rules the components already obey. If you're probing a sibling-form seam, write
   **both** forms so the differential is direct.
4. **Run `koruc`** and compare to the prediction. The signal is the **divergence**.
5. **Land the catalog entry:**
   - **Works as predicted** → write it as a green combinatorial test (`MUST_RUN` +
     `expected.txt`) in the combinatorial cluster (extend `670_NESTING_SWEEP` or its
     sibling). The interaction is now locked.
   - **Diverges** → write a **pin** next to the checker it indicts (as `220_017` sits
     in `220_FLOW_CHECKER`): `MUST_RUN` + `expected.txt` for a false-reject/false-accept
     you want fixed, or `MUST_ERROR` + `EXPECT` + `expected_error.txt` for a rejection
     you want to *keep* but whose message is wrong. The comment states **intent** (the
     shape it guards, the invariant it pins) — **never** red/green state prose (harness
     rule; tag any scaffolding `RESIDUAL:`).
6. **Self-check the gates** and hand up: the combination named, each component's
   citation, the program, the prediction, the actual `koruc` output, and which catalog
   entry you wrote.

Do NOT invent syntax to force an interesting combination. Do NOT edit a component's
own tests to make your composition pass. Do NOT report a green you didn't run.
Everything you report is verifiable by re-running.

---

## For arbiters (Lars + Claude)

1. **Verify by running, not reading.** Re-run the contestant's program through a fresh
   `koruc`; if it's a sibling-form probe, run both forms and confirm the differential.
   A divergence claim you didn't reproduce is not verified.
2. **Adjudicate the invariant.** Is this a *real* compositionality break, or does a
   stated rule legitimately forbid the composition (making a correct rejection the
   right answer)? This is the design call — same as the flow-duality rulings — and it
   is the arbiters', never the sealed contestant's. If a rule forbids it, the finding
   collapses to "the diagnostic should be better," which is still a finding.
3. **Encode it.** A confirmed working composition → green test in the combinatorial
   cluster. A confirmed break → a pin by the machinery it indicts, and (if the root is
   a checker implemented twice, à la SHAPE002) the *unification* becomes the toolchain
   work the pin names. The catalog grows; the next run targets the next uncovered pair.

**Never:** accept a probe built on invented (non-corpus) syntax; let a sealed
contestant rule that a composition "should" be legal (that's the arbiters' design
call); write red/green state prose into a test comment; file a pin without naming, in
the compiler's own terms, what it indicts.

---

## Pass / value contract

A run has earned its keep when it produces **≥1 new combinatorial catalog entry** —
either a green test locking a previously-untested composition, or a red pin that
names a real compositionality break in the compiler's own terms — for a combination
the corpus did **not** already cover, with each component grounded in a passing test
and the result reproducible by re-running. A probe that re-covers an existing
combination, or that leans on invented syntax, is not a pass. The combination is the
contribution; the compiler treating it coherently — or provably not — is the value.
