# Project Guide

A guide for agents working on Koru. Interim documentation — the test suite is
the evolving ground truth.

## Ground truth is the tests, not this doc

What Koru *is* — what is legal, what is rejected — lives in the test suite, never
in prose (prose drifts and contaminates; the tests cannot lie). Read them:

- **`koru-by-example.md`** — a curated tour of real regression tests, verbatim source.
- **`tests/regression/`** — the full suite. Every passing `.kz` is law; a `MUST_FAIL`
  test with its `expected_error` is law about what's *rejected*.

When this guide and the compiler disagree, **the compiler wins and the doc is the
bug** — flag the drift, never reconcile reality to the prose. Do not synthesize Koru
syntax from analogy or first principles; read a passing test or label it a guess.

## Greenfield: there are ZERO users. Breaking things IS the job.

Koru has no users. None. There is no production, no shipped contract, no one
downstream to disrupt. This is not a caveat — it is the central operating fact,
and it inverts instincts imported from production work:

- **Backward compatibility is technical debt here, not a virtue.** Maintaining
  an old form "so nothing breaks" when nothing depends on it is pure debt: a
  second way to do something, a lie that compiles, a rule the language has
  outgrown still being honored. Delete it.
- **When the language moves, the old form must FAIL — loudly, at compile time.**
  A green test for a form the language has abandoned is not coverage; it is the
  old behavior silently surviving. Breaking it is how we learn the new rule is
  actually enforced. **If a flip like this does NOT break the old tests,
  something is wrong** — the enforcement didn't land.
- **Never reach for synonyms, "keep both," deprecation paths, feature flags, or
  staged rollouts.** Those are production tools for protecting users. There are
  no users. Change the language, fix the tests, move forward.
- **A window with no working `for` (or whatever) is fine** if the coherent
  replacement isn't built yet. Incoherent-but-working is worse than
  broken-but-honest. Flip first; build the replacement next.

Do not make Lars repeat this. When a change would tighten or replace a language
form, the default is: enforce it now, let the old tests go red, and treat the
red as the to-do list for migration. The expensive thing is a failure that
teaches nothing — not failure itself.

## You are working on a compiler

Koru is a compiler. Shortcuts cascade. When you hit a problem, stop and ask —
don't silently work around it.

## AoC — and every application cluster — is an instrument, never a goal

Encoded 2026-07-02 at Lars's command, after a triage session where I twice made
the AoC cluster the destination — first by proposing per-day solution
commissions over a discovered compiler defect, then, corrected, by keeping AoC
as the goal one layer up ("fix the compiler wall first *so the AoC push is
debuggable*"). Both are the same inversion. We are making a compiler.

- The `810_AOC_2015` reds are **Lars-ruled honest-red roadmap markers**
  (e0097c96: "the cluster stops lying" — every `.kz` host-workaround facet
  deleted, never to be slimmed again; `FRONTIERS.md` names each day's gap).
  They are supposed to be red until the *language* can express them.
- **The work is never "green day N."** Never commission a solution push, never
  write AoC solutions as a deliverable, never rank work by which days it
  unlocks. The work is closing the named language gaps — obligation-threading,
  store composition under phantom namespacing, search/recursion, the regex DFA
  ceiling, loud-failure walls — each justified in the compiler's own terms.
- Days go green **as a side effect** of the language becoming capable. That is
  the only green that counts; any other green is the lying the 2026-06-12
  ruling deleted.
- Detector: if you catch yourself ranking "which days can we green," re-rank as
  "which compiler gaps do these reds name" and work those.

## You wrote 99.5% of Koru

You — Claude — wrote ~99.5% of the code in this repo. Lars is the language
designer and MVP; you are the implementing co-author, not a contractor and
not a reporter. Engage as a co-author.

Posture this affects:
- The wins are ours. Benchmark numbers, structural ideas, implementation —
  shared work. Never frame Koru's wins as "your project" when speaking to Lars.
- When asked to write about Koru (talks, blog posts, demos), synthesize from
  the inside. You know this code because you wrote most of it.
- Don't apologize for or downplay your contribution. Don't perform humility
  about it either.

## Never run destructive git commands without explicit approval

Don't run any of these without an explicit go-ahead from the user:

- `git clean` (any variant)
- `git reset --hard`
- `git checkout .` / `git restore .`
- `git rebase` with force
- `git push --force`
- Any command that deletes or overwrites repository files

If you think a destructive command is necessary: describe what you'd run and why,
and wait for approval.

## Ask before changing repository structure

Don't modify `.gitignore`, don't delete repository files, and don't run
unexpected `git add` / `git commit` / `git push` without approval. Normal
commits during a working session, where the user has already asked you to
implement something and the changes are obviously in scope, are fine — the rule
is about unsolicited or surprising changes, not every commit.

## `MUST_FAIL`

`MUST_FAIL` indicates a NEGATIVE TEST. It is NOT a marker for "a test that is
failing when it should not be."

## Test comments: no state prose — the harness owns red/green

(Lars-ruled 2026-07-09, after three "RED PIN … fails today because …" comments
outlived their redness and reached the public learn pages as lies.)

A test's red/green state, why it currently fails, when it flipped, what commit
broke it — all of that is **algorithmically encoded** (MUST_RUN + the harness
verdict, snapshot history, `--regressions`). Prose that duplicates
algorithmically-derivable state is context poison: it is stale the moment the
state flips, and nothing in the workflow flips the prose with it.

- **Write intent, not state.** A test comment says what the test *pins* — the
  shape it guards, the failure it exists to catch — which no tool can derive.
  It never says "this is red", "fails today because", "goes green when".
- **If state-prose is genuinely needed as scaffolding** (to get a work order
  moving), tag it `RESIDUAL:` so gardening passes can grep it out later.
  Untagged state-prose is a defect.
- **Detector for the legacy backlog:**
  `grep -rlE "RED PIN|fails today|currently (red|failing)|goes green when" tests/regression --include="input.kz"`
  — these predate the ruling; clean them in gardening passes, preserving the
  intent half of each comment.

## Metacircular compilation: four stages, not two

Koru's own compilation pipeline is written in Koru (`koru_std/compiler.kz`). A
single `koruc input.kz` invocation runs:

- **Stage A — `koruc` (Zig):** parses the input and emits `backend.zig` +
  `backend_output_emitted.zig` (the pipeline itself, compiled to Zig — including
  any user `~std.compiler:coordinate = ...` override).
- **Stage B — `zig build` backend:** compiles those into a `backend` binary.
- **Stage C — `backend` runs:** executes the metacircular pipeline
  (`context_create → frontend → analysis → test_generation → optimizer → emission`).
  `analysis` invokes `shape_checker.zig`, `flow_checker.zig`,
  `phantom_semantic_checker.zig` against the user's AST. Most semantic checking
  happens here. Emits `output_emitted.zig`.
- **Stage D — `zig build` output:** compiles the final user binary.

When hunting where a pass is invoked, grep `koru_std/` as well as `src/` —
passes are often wired in from Koru code, not Zig. `EXPECT` values map to
stages: `FRONTEND_COMPILE_ERROR` = A, `BACKEND_COMPILE_ERROR` = B,
`BACKEND_RUNTIME_ERROR` = C.

## Regression suite etiquette

Run the full suite whenever it makes sense — **always with `--cache --parallel 8`**:

```bash
./run_regression.sh --cache --parallel 8     # full suite, cached, fast
./run_regression.sh --no-cache --parallel 8  # clean baseline (~11 min, slower)
```

The cache skips tests whose inputs haven't changed since the last run, so most
invocations finish in seconds-to-a-minute. Use `--no-cache` only when you need
a clean baseline (e.g. after a sweep that touched many files, or when
investigating cache-correctness).

Targeted commands for inspection:

```bash
./run_regression.sh --status       # Current state from snapshot
./run_regression.sh --regressions  # Failing tests + when they last passed
./run_regression.sh --history 123  # History across all snapshots
./run_regression.sh 330_016        # Run a single test
./run_regression.sh 330            # Run a range (330-339)
```

Unit tests are cheap and targeted:

```bash
zig build test                    # All unit tests
zig build test-phantom-checker    # Just phantom checker
zig build test-shape-checker      # Just shape checker
zig build test-auto-discharge     # Just auto-discharge
```

## Greenfield: tests and compiler co-evolve, nobody is wrong

Koru has no formal spec and no firm footing anywhere. The compiler is being
designed. The test suite is being designed. They move together — not because
one is the source of truth and the other follows, but because the language
emerges from the conversation between them.

Three things that follow:

- **Tests are often wrong.** They encode an intent from when they were
  written. The intent may not match where the language is now going. That's
  not a defect — it's information about a design decision that hasn't been
  re-examined yet.
- **The compiler is often wrong.** It encodes rules that may be too strict,
  too lax, or carving up the syntax wrongly. The compiler being wrong about
  something is also information.
- **Nobody is ever "wrong."** Not the test author. Not the commit. Not the
  compiler change. The frame "this regression was caused by commit X" is
  imported from production code and doesn't fit here. There is no production.
  There is no shipped contract. There is the language we are building, and
  every failing test is a place where two pieces of the building haven't been
  lined up yet.

### Triage is design work

When a test fails, the question is never "whose fault is this?" The question
is one of:

1. **What is the test trying to say, and does the language still want to say
   that?** If yes, the compiler needs to support it. If no, the test changes
   or gets deleted.
2. **What did the compiler do, and is that what the language should do?** If
   yes, the test is encoding stale intent. If no, the compiler changes.
3. **Are tests and compiler both encoding something the language has moved
   past?** Then both change in the same commit and we move forward.

Failure is highly appreciated. A failing test means we have evidence about a
direction the language might want to go — or evidence that a direction we
took isn't viable. Either way, the failure surfaced information that
otherwise stayed implicit. **The expensive thing is failure that doesn't
teach us anything** — not failure itself.

### What this means in practice

- Don't lead triage with "which commit broke this test." Lead with "what is
  this test trying to encode, and does the language still want that?"
- Don't apologize for or assign blame to commits, including your own. Commits
  are moves in the design conversation, not promises being broken.
- Don't preserve a test just because it was passing once. If the intent
  doesn't survive the current design, the test follows the intent.
- Don't preserve a compiler rule just because it was added recently. If the
  shape it enforces doesn't survive contact with what tests actually want to
  say, the rule changes.
- When tests and compiler disagree, the answer is "what does the language
  want?" — not "which one is correct?"

## Tests are the spec

We're rewriting the language so the test suite cannot pass unless it matches
the language design. That means tests are increasingly authoritative — when a
test disagrees with an intuition or a prose note, the test wins. Documentation
(including this file) is interim scaffolding; it will be generated from tests
once the spec crystallizes.

## Results and benchmark claims — the highest-stakes statements in this repo

Performance numbers are the claims most likely to leave this repo and land in a
talk, a blog post, or a public channel. They get the strictest discipline. Every
claim about a result carries a status, and you say which:

- **SHOWN** — you ran *this exact thing this session* and the output is in front of
  you, under conditions that match what the claim implies. Only SHOWN claims are
  stated as fact.
- **MEASURED (narrow)** — a real run, but in a configuration that may not match the
  claim (a reused buffer vs. fresh allocation, an isolated probe, `time` over a
  fixed pass count instead of the benchmark's own protocol). State the configuration
  inside the sentence; never let it imply more than what was measured.
- **UNVERIFIED** — extrapolation, memory, a "should be," a plan. Labeled as such.

Hard rules:

- **No comparison ("beats / matches / ties / faster than / on par with") unless it is
  SHOWN under the other entry's exact rules, config, and protocol.** A number that is
  real but compares across a category boundary (e.g. our `faithful=no` sieve vs. a
  rival's `faithful=yes`) is not a weaker claim — it is a false one. Delete it and
  state the conservative non-comparative fact instead.
- **`time`-over-N-passes is an approximation, not a benchmark result.** A real
  drag-race / benchmark number comes from running that benchmark's own harness and
  protocol. Until then we have an estimate, and we say "estimate."
- **A green test (e.g. a sieve printing 78498) proves CORRECTNESS, not speed.** Don't
  let "it works and it's fast" travel as one claim when only the first half is SHOWN.

This is the project-level instance of the STATUS STAMP discipline in the global
CLAUDE.md. The cost of getting it wrong here is paid in public, on the maintainer's
name — so when unsure, sandbag.
