# Transparency float — koru — 2026-06-07

- **target:** `/Users/larsde/src/koru`
- **run:** `wf_8dd9285b-c8f` · 7 contestants · 21 watcher candidates
- **machine-readable backlog:** [`commission_queue.json`](commission_queue.json)

## Commission queue (ranked installable watchers)

| # | sev/build | watcher | corroborated by |
|---|---|---|---|
| 1 | med/high | Diagnostic-code registry coherence: emit ⊆ declared, declared ⊆ emitted, pinned ⊆ declared | two_source_drift.1, two_source_drift.4, unenforced_convention.1, unenforced_convention.3, dangerous_change_shape.3 |
| 2 | med/high | Product version is one number across all five sites | two_source_drift.3 |
| 3 | high/high | canonicalize post-condition: every DottedPath gets a module_qualifier, no silent null-skip downstream | silent_invariant.1 |
| 4 | high/high | No orphaned expected.txt that degrades to a false-green compile-only test | unenforced_convention.2 |
| 5 | high/high | Hand-authored doc code blocks must compile against the live compiler (stderr-gated, not exit-code) | two_source_drift.2, rules_aware.1, rules_aware.2 |
| 6 | med/med | A behavior-changing fix(...) under src/ must land with a regression test | unenforced_convention.4 |

## Top pick

**Diagnostic-code registry coherence (emit ⊆ declared, declared ⊆ emitted, pinned ⊆ declared)**

_Why:_ Highest (value × buildability) and the single most-corroborated invariant in the sweep — FOUR lenses (two_source_drift.1, two_source_drift.4, unenforced_convention.1, unenforced_convention.3/dangerous_change_shape.3) independently walked into the same file, src/errors.zig. It exercises the rail cleanly: a deterministic three-set FACT scan over a closed registry, with a real violation on BOTH primary arms verified live (KORU200 emitted-but-undeclared at main.zig:3604; 11 declared-but-dead codes), and a clean control arm (test pins all resolve today, so the pinned-arm stays silent now and only fires on a future rename). The dead-code arm is the one place a judge earns its keep — distinguishing a genuinely-reserved code from a forgotten one — so it also demos the fact×intent product gate, while the orphan-emit and rotten-pin arms are pure mechanical set-difference. One engine, four lenses, two live anchors, one clean control.

_Build sketch:_ FACT scan (no LLM): (1) DECLARED = parse members from the `pub const ErrorCode = enum(u16)` block in src/errors.zig:3-86. (2) EMITTED = union of (a) regex `error\[([A-Z]+[0-9]+)\]` raw string literals across src/**.zig, and (b) `\.((KORU|PARSE|TYPE|SHAPE)[0-9]+)\b` enum-tag uses across src/ + koru_std/, minus the errors.zig declaration lines themselves. (3) PINNED = `(KORU|PARSE|TYPE|SHAPE)[0-9]{3}` over tests/regression/**/{EXPECT,expected*.txt}. Emit three diffs: ORPHAN_EMIT=EMITTED\DECLARED, DEAD=DECLARED\EMITTED, ROTTEN_PIN=PINNED\DECLARED. JUDGE axis (gates ONLY the DEAD arm): code_is_aspirational ∈[-1,1] — +1 the enum line carries an explicit reserved/aspirational comment, -1 a code sits with zero emit sites under no such marker. PRODUCT GATE: ORPHAN_EMIT and ROTTEN_PIN fire pure-FACT (set-diff >= 1, deterministic, no judge). DEAD fires = FACT(DEAD grows on this diff) × INTENT(code_is_aspirational <= -0.5) × gain >= floor. ANCHOR it must fire on: HEAD state — ORPHAN_EMIT={KORU200} (main.zig:3604) and DEAD={KORU031,KORU042,KORU043,KORU052,KORU060,KORU061,KORU070,KORU082,KORU090,KORU091,PARSE002}. CONTROL it must stay silent on: KORU030 (36 emit sites) and KORU034 (1 site) — both declared AND emitted; and the current PINNED set, which fully resolves into DECLARED today, so ROTTEN_PIN=∅ until a future rename. A benign enum reorder/rename that preserves all three set-memberships scores every diff empty and stays silent.

## Synthesis (full)

## The strongest signal: four lenses converge on ONE registry — `src/errors.zig`

The most-corroborated invariant in the whole sweep is **the ErrorCode enum at `src/errors.zig:3-86` is the single source of truth for diagnostic codes, and nothing keeps the things that reference it honest.** Four independent lenses walked in from four different doors and all landed on this same file:

- **two_source_drift.1** — a code is *emitted* (`error[KORU200]`) that isn't *declared* in the enum. Verified live: `src/main.zig:3604` prints `error[KORU200]: Ambiguous module structure` and returns `error.ModuleNotFound` with a `// TODO: Add proper AmbiguousModule error` — KORU200 is absent from the enum (it stops at KORU121).
- **unenforced_convention.1** — codes *declared* in the enum that are *never emitted*. Verified live: exactly 11 dead codes — KORU031, KORU042, KORU043, KORU052, KORU060, KORU061, KORU070, KORU082, KORU090, KORU091, PARSE002 all have `emit_sites=0` (vs KORU030 with 36, KORU034 with 1). KORU061 "Subflow recursion detected" is named in CLAUDE.md as real semantics yet fires nowhere.
- **two_source_drift.4 / unenforced_convention.3 / dangerous_change_shape.3** — codes *pinned by tests* (`CONTAINS error[KORUxxx]`, expected.txt) that could orphan against the enum. Clean control today (all referenced codes resolve), but the trap is one rename away.

That is the dictionary problem from three sides at once: **emit→enum (KORU200 lives outside the dictionary), enum→emit (11 words in the dictionary nobody speaks), test→enum (pins that could rot).** A single FACT scan that materializes three sets — `EMITTED` (raw `error[CODE]` literals + `.CODE` enum uses), `DECLARED` (enum members), `PINNED` (test references) — and diffs them pairwise covers all four lenses with one mechanical engine. This is the buy.

## The second tier: two clean fact×intent watchers with a real anchor AND a real control

- **two_source_drift.3 — the version is four numbers.** Verified live: `src/main.zig:36`=0.1.7, `koru.json:3`=0.1.4, CHANGELOG newest=`[0.1.3]`, `src/project_template.zig:93/108`=0.1.0, with the zon `0.0.0` correctly a package-dedup placeholder to whitelist. CHANGELOG.md:87's own "now kept in sync" note is the receipt that this drifted before. Pure set-difference, deterministic, fires NOW.
- **silent_invariant.1 — canonicalize's post-condition has no enforcement and a silent consumer.** Verified live: `src/canonicalize_names.zig:11` documents "After this pass, ALL DottedPaths have a module_qualifier set"; the walker is a hand-maintained switch; `src/continuation_codegen.zig:31` is `if (invocation.path.module_qualifier) |mq| {...}` — when null, the *entire* module-prefix block is skipped and a bare unqualified symbol is emitted. This is the textbook trust→sight trap: a docstring invariant + a silent `orelse` consumer + no exhaustiveness check. It fires on a *future* commit (new path-bearing AST variant), so it's a true watcher, not a today-linter.

## The third tier: real but lower leverage

- **unenforced_convention.2 — orphaned expected.txt.** Verified: 9 dirs have expected.txt with no MUST_RUN/EXPECT. All 9 are FAILURE today, so the SUCCESS-without-FAILURE gate correctly holds fire — it's latent, flips to a false-green alarm the instant one compiles. Good watcher, but it guards the test harness rather than the product.
- **two_source_drift.2 / rules_aware.1 — README doesn't compile.** Verified: `/tmp/readme_block.kz` → `error[PARSE003]: imports are bare — drop the ~`. Real, high-severity, front-door. **One wrinkle I confirmed that the candidates understate: koruc exits 0 even on PARSE003** — so the faucet MUST grep stderr for `error[`, never trust exit code. Slightly lower than the registry because it's a single block and the fix is "rewrite the README," not a recurring invariant.
- **unenforced_convention.4 — fix-without-test.** Verified: b203f6cb (`fix(codegen)`) touches only src/codegen_utils.zig, zero tests/; control d87beceb lands with its test. Clean anchor+control, but it's a process-discipline watcher (git-archaeology), weaker payoff than a product invariant.

## What I cut and why

- **rules_aware.3 / rules_aware.4 (governance dangling refs / stale verification citations)** — low severity, and they fire on *documentation that was always aspirational* (SPEC.md/KORU.md never existed). That's closer to "this doc was never true" than "trust silently broke." Cut as low-payoff.
- **silent_invariant.2 (empty segments) / silent_invariant.3 (is_impl snapshot) / reachable_bad_state.3 (undefined AST var)** — all "med/low or med/med, not currently broken, dataflow-hard to build." Real traps but the FACT scan (whole-function dominator/dataflow analysis) is expensive and noisy, and there's no current violation to anchor on. Deprioritized, not killed — they're the right shape, wrong cost/benefit for first commission.
- **dangerous_change_shape.2 (dual mangler divergence)** — clever, but "structurally compare two predicate bodies" is the hardest FACT to build reliably and has no current divergence to anchor. Park it.
- **reachable_bad_state.1 (unsigned depth underflow)** — genuinely good (high/high, real fixed bug at b203f6cb), but it's a guard-presence linter over depth counters; it overlaps the fix-without-test idea and is more of a Zig-idiom lint than a head-carried-trust watcher. Keep in queue, below the registry.

I did NOT re-verify reachable_bad_state.1's guard-counting or dangerous_change_shape.1's diagnostic-pin scan against the tree (read the grounding, didn't run the scans) — ranking them on the candidates' own evidence plus the registry corroboration they share.