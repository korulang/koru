# Challenge 007 — Fable Commission: field-granular obligation narrowing

This supersedes the earlier two-symptom queue. Challenge 007's obligation findings
all trace to **one root feature that isn't built**: a record's obligation-bearing
fields cannot be discharged independently. Build that, and the symptoms fall out.

Read first, in order:
1. `concepts/frag-field-granular-obligation-narrowing.md` — the model and the *why*
   (consume→vanish→narrow→collapse→poison; implicit narrowing; destructure falls out).
2. The spec pins below (they ARE the acceptance criteria).
3. Repo standards: `CLAUDE.md`, `AGENTS.md`.

## ⚠️ Keep your eyes open — float, don't blindly satisfy

This spec was designed in one sitting with Lars. It is good, but there is a real
(small) chance it's missing or mis-stating something you'll only discover while
implementing. So:

- **If a pin looks wrong, do NOT edit it green.** Stop, say exactly why you think
  it's wrong, and float it back for a ruling. (`AGENTS.md`: understand tests before
  changing them; the one banned move is red→edit-green→claim-success.)
- **If the design needs a decision the spec doesn't cover** (especially a diagnostic
  wording — see "un-pinned" below), float it. The obligation model is Lars's.
- A pin you made green by *understanding* and building the feature is the goal. A pin
  you made green by contorting the checker to dodge it is worth less than the red was.

## The root

Obligations are tracked by **binding-name string** (`phantom_semantic_checker.zig`
~2604) with a fragile `.suffix` fallback, so a **field projection `s.a` is not a
first-class tracked entity**. That is why `dispose(x: s.a)` reports the misleading
`"argument 'x' carries no obligation here"` even though `s.a` visibly holds one. The
build: make a field-projected obligation a first-class entity **keyed by path**
(`s.a`, `s.b`), consume it on discharge, and **narrow the source record's type**
down-flow — a field vanishes when discharged; one field left collapses to a scalar
(`210_149`) and poisons the base binding.

## Acceptance — the spec pins (all on this branch)

Positive (`MUST_RUN`, must go GREEN):
- `330_101` discharge both fields of `{h!,g!}` → clean.
- `330_104` discharge all three of `{a!,b!,c!}` → clean (narrows across >1 step + mid-collapse).
- `330_105` discharge the sole obligation of `{h!, n:i64}` → plain `n` survives, readable via `s.n`.
- `330_106` discharge out of declared order → clean (fields independent).
- `330_107` full destructure `{h,g}` then discharge each scalar → clean.
- `330_108` destructure `{h}` of `{h!, n:i64}` (drop plain `n`) then discharge → clean.

Walls (`MUST_FAIL`, must assert correctly):
- `330_102` discharge one, drop → KORU030 on the remainder. (already green — keep it green)
- `330_103` partial destructure omits an *obligation* field → KORU030. (already green)
- `330_109` double-discharge a field → **`already discharged`** (the `:2597` message), NOT
  today's "carries no obligation". Currently wrong-error red; flip it to the right diagnostic.

Symptoms that must fall out of the root fix (don't patch these directly):
- `330_098` obligation-in-record-field under `for ! each` — false-accept, must catch KORU030.
- `330_099` (already green) / `330_100` record-field obligation through a subflow — the
  subflow path must give the same precise phantom diagnostic as a direct call, not degrade.

Also: the misleading `330_101` diagnostic (`RESIDUAL` in that file) should stop blaming the
value once projections are tracked.

## Un-pinned — exists, but NOT spec'd (needs Lars's diagnostic wording; float when you reach it)

- **Poison-base**: using `s` as a whole record after it collapsed to a scalar must be rejected.
  Diagnostic wording is Lars's call. Don't invent a wall; surface what you observe.
- **Branch chokepoint**: symmetric discharge across arms → clean; asymmetric → reject with a
  "divergent obligation signatures at the chokepoint" diagnostic (wording is Lars's).
- **Nested obligations** (an obligation field that is itself a record with obligations): v2.

## Done

The six `MUST_RUN` pins green, the three walls asserting correctly (incl. `330_109`'s
diagnostic), `330_098`/`330_100` falling out, and nothing else in the suite regressed —
built by *understanding and extending the obligation model*, with anything the spec got
wrong floated rather than papered over.
