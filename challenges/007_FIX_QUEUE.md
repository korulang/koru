# Challenge 007 — Fix Queue (for a Fable implementation session)

Compiler gaps surfaced by the 007 combinatorial-composition fleets. Each item is
a red pin in the suite with a raw reproduction, the suspected checker site, and
the design question that must be ruled **before** implementation. Both items are
**obligation-model** issues — that model is Lars's, so each carries a ⛔ RULING
gate. A Fable session implements an item only after its gate is green.

Run everything from the worktree `/Users/larsde/src/koru-challenge-007`
(`./zig-out/bin/koruc`). Verify with `./run_regression.sh <id>`.

---

## Item 1 — FALSE-ACCEPT: record-field obligation leaks under for-each  🔴 dangerous

- **Pin:** `tests/regression/300_ADVANCED_FEATURES/330_PHANTOM_TYPES/330_098_obligation_record_field_under_for_each` (`MUST_FAIL` / `EXPECT` KORU030 "was not discharged").
- **Symptom:** an obligation carried in a **record field** (`{ h: *Handle<owned!>, … }`), dropped inside a `for(0..n) ! each` body, compiles and runs silently — **no KORU030**, three handles leak. `koruc` exit 0, prints `n=0/10/20`.
- **Why it's a bug (grounded in the corpus):** both halves enforce this catch in
  isolation — `330_096_obligation_in_record_field` (field-level) and
  `330_053_for_loop_obligation_escape` (for-loop escape) are BOTH `MUST_FAIL`
  expecting KORU030. `330_098` is their composition; the checker loses the
  field-level obligation once the record is bound inside a for-each iteration.
- **Suspected site:** the phantom/obligation pass that seeds per-iteration
  tracking (`phantom_semantic_checker.zig`) vs. the field-level obligation walk —
  the field obligation on `r.h` is never entered into the tracked set inside the
  `! each` scope. Same class as the (now-fixed) 220_017 SHAPE002 "check
  implemented twice diverges under composition".
- **⛔ RULING (Lars):** *Confirmed a real bug* (Lars, this session) — a dropped
  record-field obligation under for-each MUST be caught (KORU030), matching the
  330_096 shape. **Gate: GREEN.** The remaining design surface is only *where* the
  fix lands in the obligation model — flag it to Lars if the fix forces a model
  choice, otherwise implement to make 330_098 catch KORU030.
- **Done when:** `330_098` flips to PASS (the leak is caught with
  `error[KORU030] … was not discharged`), and 330_096/330_053 stay green.

---

## Item 2 — BAD-DIAGNOSTIC: explicit discharge of a record-field obligation ignored under subflow  🔴 needs ruling first

- **Pins:**
  - `…/330_099_obligation_record_field_leak_under_subflow` — **green**: record-field
    obligation returned through a subflow, never discharged → KORU030 fires
    correctly across the subflow boundary. (Locks the correct catch; not a bug.)
  - `…/330_100_obligation_record_field_explicit_discharge_misdiagnosed_under_subflow`
    — **red** (`wrong-error`): the *same* obligation with an explicit
    `dispose(res.h)` in source. Expected the precise diagnostic; got the generic
    auto-discharge `"was not discharged"` (KORU030), which silently ignores the
    explicit discharge call.
- **What was measured:** a direct-call control (no subflow) with the same explicit
  `dispose(res.h)` is rejected by `phantom_semantic_checker.zig:2696` with a
  *specific, argument-located* message ("Phantom state mismatch: argument 'h'
  carries no obligation here …"). The subflow-routed form instead falls through to
  the generic `auto_discharge_inserter.zig` wall — a strictly worse diagnostic for
  the same intent.
- **The deeper question (contestant-flagged, verified):** manual discharge of a
  record-field obligation (`dispose(res.h)`) is **already rejected even without a
  subflow**. So this is not purely a message bug — it sits on top of an unsettled
  model question.
- **⛔ RULING NEEDED (Lars) — obligation model:** *Should manually discharging a
  record-field obligation be legal?*
  - If **YES** (you can `dispose(res.h)`): then BOTH the direct-call and
    subflow-routed forms are bugs — the discharge must be *accepted*, not rejected.
    330_100 should flip to a **green MUST_RUN**, and the fix is in the phantom
    checker's handling of field-projected obligation arguments.
  - If **NO** (record-field obligations are auto-discharge-only): then the correct
    behavior is a *good rejection* — and 330_100's finding narrows to "the subflow
    path must give the same precise `phantom_semantic_checker` diagnostic as the
    direct call, not degrade to the generic auto-discharge message." Fix is
    diagnostic-routing under the subflow boundary.
- **Gate: RED until Lars rules YES/NO above.** A Fable session must not pick a
  direction here — the two directions produce opposite tests.
- **Done when:** per the ruling — either 330_100 becomes a green MUST_RUN (discharge
  accepted), or it stays MUST_FAIL with the precise `phantom_semantic_checker`
  diagnostic surfaced across the subflow boundary.

---

## Not in scope (surfaced, not bugs)

- The `usize`→`i64` loop-index cast friction (a for-each index needs
  `@as(i64, @intCast(i))` to feed an `i64` event param) — pre-existing, grounded at
  `810_092_day09_part2:31`, orthogonal to composition. Note only.
