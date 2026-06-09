# Challenge 004: Map the Signal Surface of the Koru System

> **To the agent reading this brief: you ARE the contestant, not the assistant.**
> This is a MAP, not a build. Do not write a model, an adapter, or a dispatch
> pipeline. Do not ask which signals matter — go read the real repos and tell us
> what's actually there. The deliverable is a grounded, annotated survey plus one
> ranked recommendation. Arbiters judge it by spot-checking that every mapped
> signal points at a real table / file / commit / test you actually read.

This is **step zero** of the methodology (read `docs/METHODOLOGY.md` —
"Step zero: map the signal surface" — and `docs/SELF_DRIVING.md` first). Before we
model or dispatch anything on Koru, we survey what the Koru *system* emits. The map
is the foundational artifact every later challenge aims at; without it, modeling and
dispatch are guesses.

## The target — the Koru system (two repos, one surface)

- **`~/src/koru`** — the metacircular compiler. 938 commits (since 2025-12). Real
  surfaces: `run_regression.sh` / `run_single_test.sh` over **755 regression tests**
  in `tests/regression/<CLUSTER>/<NNN>/` (13 clusters, 000_CORE_LANGUAGE …
  900_EXAMPLES_SHOWCASE); `status.json`; `CHANGELOG.md`; `benchmarks/`; the git log.
- **`~/src/korulang_org`** — the website (Convex backend). 894 commits (since
  2025-10). Real surfaces: Convex tables **`feedback`** (pageUrl/content/status/
  priority — explicit, carries a source target), **`testRatings`** (the rating
  stream), `statusUpdates`, `liveStatus`, `presentations`/`slides`; the blog (the
  "regression suite got 22x faster" post is a real timing event); the git log.
- **Sidetrack** (`:6274`, multi-tenant in-mem event sink, `/stream` SSE) — a faucet
  *if* Koru's runtimes are instrumented into it. Check before assuming.

These are siblings — the compiler and its site — so treat them as ONE signal
surface for one system. The self-driving loop we're aiming at (feedback on the site
→ dispatch an agent at the compiler/lesson source) spans both.

## What you produce — the annotated signal map

Answer the two questions, kept separate, **grounded in real reads**:

### 1. What signals already exist (the as-is inventory)
Every stream the Koru system leaks today. For each, a row with:
- **signal** — what it is, concretely.
- **faucet** — arrival / work / money / cost-health.
- **explicit or implicit** — does it already carry `{magnitude, why, where}`
  (a human declared it, with a target), or must a world model *derive* the surprise
  from it? (`feedback`/`testRatings` are explicit; commit cadence, regression
  timing, the firehose are implicit.)
- **dispatch target?** — does it carry a `where` (a file, a test id, a lesson/page)?
- **evidence** — the real table / file / commit / test you read.

### 2. What we'd change to emit meaningful signals (instrumentability)
The cheap emissions that would unlock a model we can't build from exhaust today.
For each: the **seam** (where it'd fire), the **event**, the **model it unlocks**,
and **why it's worth it**. (Tie every proposed change to a named consuming model —
no model, no emit.) Candidates surfaced already: a wall-time + pass/fail envelope
from `run_regression.sh`; `unit.completed` / status emission at the seam; session
lifecycle beats.

### 3. The ranked recommendation — which loop to close first
End with ONE call: given the map, which loop should we close first, and why —
using the **blast-radius** rule (debut autonomous dispatch where a misfire costs a
wasted doc-fix, not a wrong action). State the faucet, the surprise, the dispatch
target, and the safety argument. (Strong prior: the explicit **feedback → dispatch
an agent at `pageUrl`** loop. Confirm or overturn it from what you actually find.)

## What makes this great (ranked)

| Property | Weak | Strong |
|---|---|---|
| **Grounded** | "Koru probably emits test results" | every row cites a real table/file/commit/test you read |
| **Annotated for routing** | a flat list of signals | each tagged faucet / explicit-vs-implicit / has-a-target / as-is-vs-change |
| **Honest about the firehose** | lists 3 tidy signals | names the noisy high-volume faucets too, and says what's noise |
| **Instrumentability tied to models** | "we should log more" | each proposed emission names the model it unlocks |
| **Decisive recommendation** | "many loops are possible" | one ranked first-loop with the blast-radius argument |

## Valid outcomes (ADD contest semantics)

1. **Bridge** — a complete, grounded, annotated map + a defensible first-loop
   recommendation. We know what to build next and why. This is the win.
2. **Frontier** — a real surface that resists the framework (a signal that isn't
   cleanly any of the four faucets, or where "explicit vs implicit" genuinely blurs).
   Pin it precisely — that tension is a contribution, not a failure.
3. **Breakthrough** — the map reveals the methodology itself needs a new concept to
   describe Koru's surface. Flag it for arbiter review.

A precise "here's what's really there, and here's the honest gap" beats a tidy map
that invented signals to look complete.

## Anti-patterns (auto-weak)

- **Guessed signals.** Anything not traced to a real table/file/commit/test.
- **Mapping without reading the repos.** The brief names surfaces; you must open them.
- **Skipping the firehose** because it's noisy. High-volume implicit faucets
  (Sidetrack, the full commit/test stream) belong on the map, tagged as such.
- **A recommendation with no blast-radius reasoning.** "Close the trading loop
  first" with no safety argument is auto-weak.
- **Building anything.** This is a survey. A model or adapter is out of scope and
  signals you didn't understand the task.

## Where it goes

- A single map document: `koru/SIGNAL_MAP.md` (in `~/src/koru`) or returned as the
  deliverable — the two annotated tables + the ranked first-loop recommendation.
- Read before you start: `docs/METHODOLOGY.md`, `docs/SELF_DRIVING.md`,
  `~/src/korulang_org/convex/schema.ts` + `convex/feedback.ts`, `~/src/koru/run_regression.sh`
  + a `tests/regression/` cluster, and a `git log` of each repo.

## For arbiters (Lars + judge agent)

**Commission sealed:** hand the contestant only this file + the two docs above.
Can be run **1-wide** (one comprehensive survey — validate the brief on Koru first,
as we did with 003) or **N-wide** for coverage (different agents surface different
signals; then merge the maps and dedup). Survey favors comprehensiveness, so if
N-wide, a merge/synthesis pass is part of the job.

**Judge pattern:**
1. Spot-check 5 rows: does each cite a real surface? Open it; confirm.
2. Is every signal annotated (faucet / explicit-vs-implicit / target / as-is-change)?
3. Are the noisy/firehose faucets present, not just the tidy ones?
4. Does each instrumentability proposal name the model it unlocks?
5. Is the first-loop recommendation decisive and blast-radius-justified?
6. Rank: a grounded map with a defensible first loop > a grounded map with no call >
   a tidy map with invented signals.

---

*Signal-map challenge — 2026-06-06. The first real swing on Koru. It produces the
map the modeling and dispatch challenges aim at — and almost certainly points at
the feedback→dispatch loop as the safe place to debut the self-driving half. If
that loop later closes on Koru, this map is where it started.*
