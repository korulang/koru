# Koru — project guide

Koru is a compiler, and the toolchain is the product. This file holds only what's
specific to working *here*; it points rather than encodes.

**Start with the `koru-toolchain` skill** — how to compile, how to run the suite,
the four-stage metacircular pipeline, what bites you. Operational how-to lives
there, never here. For a declaration surface on any file, `koruc <file> glance`
before reading it.

## Ground truth is the tests

What Koru *is* — what's legal, what's rejected — lives in the suite, never in
prose. Every passing test is law; a `MUST_FAIL` test with its `expected_error` is
law about what's *rejected*. (`MUST_FAIL` marks a negative test. It never means "a
test that is failing when it shouldn't.")

- **`koru-by-example.md`** — curated tour of real tests, verbatim source.
- **`tests/regression/`** — the full suite.

When this guide and the compiler disagree, the compiler wins and the doc is the
bug. Never synthesize Koru syntax from analogy — read a passing test, or label it
a guess.

## Read the membrane on startup

The durable *whys* live in the belief garden — the store declared in
`.claude/membrane.json` (currently the `koru-membrane` sibling repo), tended via
the `membrane` skill. It holds what the code structurally cannot: repudiations,
irreducible rationale, regime changes. Read it before improvising anything it
governs; a belief that settles the surface you're about to touch usually already
exists.

The doctrine that used to live in this file now lives there:

- `frag-milestone-suites-are-instruments` — AoC and every application cluster
  surface toolchain gaps and then drop off the work list. Never "green day N."
- `frag-greenfield-breaking-is-the-job` — zero users; backward compatibility is
  debt; when the language moves, the old form must fail loudly.
- `frag-tests-and-compiler-coevolve` — no formal spec, both sides are often
  wrong, nobody is to blame, and triage is design work.

Keep the corpus honest: a belief that *could* live as a passing test or a
`MUST_FAIL` wall belongs in the suite, not in prose. Prefer evolving it out into
running code and leaving a pointer.

## Test comments: intent, never state

A test's red/green state, why it fails today, when it flipped — all
algorithmically derivable (MUST_RUN + harness verdict, snapshot history,
`--regressions`). Prose duplicating it is stale the moment the state flips, and
three such comments once reached the public learn pages as lies.

Write what the test *pins* — the shape it guards — which no tool can derive. If
state-prose is genuinely needed as scaffolding, tag it `RESIDUAL:` so gardening
can grep it out. Untagged state-prose is a defect.

    grep -rlE "RED PIN|fails today|currently (red|failing)|goes green when" tests/regression --include="input.kz"

## Benchmark claims

The global status stamp applies, with two Koru-specific edges:

- **`time`-over-N-passes is an estimate, not a benchmark result.** A real number
  comes from that benchmark's own harness and protocol. Say "estimate" until then.
- **A green test proves correctness, not speed.** Don't let "it works and it's
  fast" travel as one claim when only the first half is SHOWN.

These leave the repo on Lars's name, so when unsure, sandbag.
