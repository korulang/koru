# Koru Technical Debt Workdoc (Strengthened)

**Created:** 2026-02-05  
**Updated:** 2026-02-05  
**Purpose:** Systematic hardening of correctness + diagnostics + parser stability  
**Status:** 479/575 tests passing (83.3%)

---

## 0) Ground Truth and Guardrails

**TEST-DRIVEN IS THE ONLY WAY.**

Every fix follows this sequence:
1. **Find or write a failing test** that reproduces the issue
2. **Verify it fails** for the right reason
3. **Fix the code** to make the test pass
4. **Run full regression** to verify no breakage
5. **Only then** is the issue resolved

No exceptions. No "I fixed it, tests probably pass." No "this is obviously correct."

**Baseline:** 479/575 passing (83.3%). Never regress below this.

---

**Ground truth:** tests only (regressions + unit tests with SUCCESS markers).
**No docs as truth:** treat all prose as provisional unless backed by tests.
**Performance first:** fixes must not degrade hot paths without measured justification.
**No Zig escape hatches:** prefer Koru-native semantics; Zig is last resort.
**Prefer subflows over procs:** if both can represent behavior, use subflows.
**Prefer $std/io over Zig std:** keep Koru std as primary surface.

---

## 1) Scope and Non-Goals

**In scope**
- Parser correctness and robustness
- Diagnostics quality (errors with location and intent)
- Semantic correctness (phantom obligations, branch handling)
- Emission correctness (type qualifiers preserved)
- Test suite integrity

**Out of scope (for now)**
- New feature expansion outside listed issues
- Major architecture rewrites without a failing repro
- Style-only refactors not tied to correctness or tests

---

## 2) Definitions

- **parse_error node:** AST node inserted during lenient parsing; should never reach emission in strict mode.
- **transform:** comptime event with [transform] that returns a new Program.
- **branch coverage:** each required branch in an event must be handled.
- **phantom obligation:** type state like `File[open!]` that must be discharged or passed.

---

## 3) Priority Map (Current)

1. **P0 Trust / Correctness**
2. **P1 Parser Stability**
3. **P2 Diagnostics / DX**
4. **P3 Cleanup and Test Hygiene**

Rationale: correctness and parser stability unblock everything else and prevent silent bad output.

---

## 4) Critical: Correctness Issues (P0)

### C1. Parse Errors Can Silently Propagate
**Problem:** `parse_error` nodes can reach emission, causing Zig errors instead of Koru errors.  
**Location:** `src/parser.zig`, `src/main.zig`  
**Symptoms:** broken output, opaque Zig errors.  
**Fix sketch:** strict mode check after parse; fail if AST contains parse_error.  
**Acceptance criteria:**
- A minimal invalid input yields a clear Koru error (file/line/column).
- No parse_error node survives into backend/emitter in strict mode.
**Tests:** add regression with invalid syntax → expect Koru error.

### C2. Nested When Guards Parse as Errors
**Problem:** nested `when` guards can become parse_error nodes.
**Location:** `src/parser.zig` (`parseNestedContinuations`, `parseBranchContinuationBase`)
**Fix sketch:** carry guard context through nested continuation parsing.
**Acceptance criteria:** example in this doc parses and emits correct AST.
**Tests:** add regression using nested when guards.

### C3. Label Jump Phantom Obligations Not Fully Enforced
**Problem:** obligations can be dropped on label jumps without errors.  
**Location:** `src/phantom_semantic_checker.zig`, `src/auto_discharge_inserter.zig`  
**Fix sketch:** audit jump paths, ensure obligations are passed/discharged; add explicit checks.  
**Acceptance criteria:** label jumps that drop obligations fail.  
**Tests:** regression with label jump dropping `Type[state!]` → error.

### C4. Unknown Event References Lack Location Info
**Problem:** error lacks file/line/column + event name.  
**Location:** `src/shape_checker.zig`  
**Fix sketch:** thread source locations through resolution; include event path.  
**Acceptance criteria:** KORU040 or equivalent includes event name + location.  
**Tests:** regression referencing unknown event in a flow.

---

## 5) High: Parser Robustness (P1)

### H1. Zig Code Detection Heuristics Misfire
**Problem:** `looksLikeZigCode()` false positives, e.g. `std.log.info()` in Koru.  
**Location:** `src/parser.zig`  
**Fix sketch:** stronger heuristics (require Zig keywords + assignment/decl).  
**Acceptance criteria:** valid Koru with `std.` parses as Koru.  
**Tests:** regression that previously mis-detected Zig.

### H2. Multi-Line Invocation Brace Depth
**Problem:** brace depth not tracked across lines → truncated content.  
**Location:** `src/parser.zig` multi-line parsing logic  
**Fix sketch:** proper depth tracking for `{}`, `()`, `[]`, with string/comment awareness.  
**Acceptance criteria:** nested braces in multi-line invocations parse fully.  
**Tests:** regression with nested braces across lines.

### H3. Phantom Type Bracket Ambiguity
**Problem:** `[` after type ambiguously parsed as phantom vs array literal vs slice.  
**Location:** `src/parser.zig` type parsing, phantom annotation detection  
**Fix sketch:** phantom annotations valid only in type position; arrays only in value position.  
**Acceptance criteria:** phantom + array literal both parse correctly.  
**Tests:** regression for each ambiguous case.

---

## 6) Medium: Developer Experience (P2)

### M1. Error Messages Show Zig Errors
**Problem:** codegen emits invalid Zig instead of Koru diagnostics.  
**Location:** semantic checks, emitter  
**Fix sketch:** pre-emit validation; surface Koru errors.  
**Acceptance criteria:** Koru error instead of Zig error for known failures.  
**Tests:** regression where type mismatch is caught before emission.

### M2. Terminal `_` on Non-Void Branches
**Problem:** `_` discard on payload branches compiles but generates invalid Zig.  
**Location:** `src/flow_checker.zig`  
**Fix sketch:** enforce branch payload must bind or explicitly discard.  
**Acceptance criteria:** `_` on payload branch errors.  
**Tests:** regression for payload discard.

### M3. Cross-Module Type Prefix Handling
**Problem:** `?*`, `[]const`, `?[]` modifiers lost across modules.  
**Location:** `src/type_registry.zig`, `src/emitter_helpers.zig`  
**Fix sketch:** normalize type representation; preserve modifiers during emission.  
**Acceptance criteria:** emitted types retain all qualifiers.  
**Tests:** regression for `?*` and `[]const` on imported types.

---

## 7) Low: Cleanup (P3)

### L1. Dead Code Removal
**Targets:** old build system remnants, deprecated `~impl` scaffolding, unused emitter paths.  
**Acceptance criteria:** remove with no behavior change; tests unchanged.

### L2. Test Infrastructure Gaps
**Issues:** missing TODO/SKIP markers, perf tests lacking input.kz, parallel aggregation.  
**Acceptance criteria:** all test dirs labeled; no orphaned tests.

### L3. ShapeChecker Leak (Documented)
**Problem:** small leak from allocator ownership mismatch.  
**Fix sketch:** unify allocator usage or track ownership.  
**Acceptance criteria:** leak-free in debug allocator.

---

## 8) TODO Tests (75 total, key blockers)

| Test | Issue | Complexity |
|------|-------|------------|
| 210_020 Field Punning | `{ x }` → `{ x: x }` sugar | Medium |
| 310_032/033 std/build | Build system module | High |
| 310_023 Scoped Patterns | `~file.*` not recognized | Medium |
| 310_025 Qualified Patterns | `~std.io:print*` fails | Medium |
| 915 When Guards at Callsite | `~foo() when x > 0` | High |
| 310_026 Type Mismatch | Metatype field types | Medium |
| 220_004 Cross-Module Nested | Event resolution | Medium |
| 231 Inline Flow Edge | No continuation case | Low |
| 350_003 Pattern Dispatch | Pattern branching | High |

---

## 9) Execution Plan (Two-Pass)

### Pass 1: Fix and Prove (Strict correctness)
1. C1 Parse error propagation
2. C4 Unknown event location (quick win)
3. H2 Multi-line brace depth
4. C2 Nested when guards
5. H3 Phantom bracket ambiguity
6. C3 Phantom obligations in label jumps

### Pass 2: Harden DX + cleanup
1. H1 Zig detection heuristics
2. M1 Error messages before Zig
3. M2 Terminal `_` validation
4. M3 Cross-module type prefixes
5. L1-L3 cleanup

---

## 10) Acceptance Checklist (Per Issue)

**Before writing any fix code:**
- [ ] Failing test exists in `tests/regression/...`
- [ ] Test fails for the RIGHT reason (not a different bug)
- [ ] Test is minimal (isolates the issue)

**After fix:**
- [ ] The specific test now passes
- [ ] `./run_regression.sh` shows no new failures
- [ ] Pass count >= 479 (never regress baseline)
- [ ] Error messages include location + event when applicable
- [ ] No obvious hot-path regression without justification

**If no failing test exists, CREATE ONE FIRST. The fix is not the first step.**

---

## 11) Testing Commands

```bash
./run_regression.sh --status
./run_regression.sh --regressions
./run_regression.sh 210
zig build test
```

---

## 12) Tracking (Fill in as we work)

| ID | Status | Commit | Notes |
|----|--------|--------|-------|
| C1 | todo | | |
| C2 | todo | | |
| C3 | todo | | |
| C4 | todo | | |
| H1 | todo | | |
| H2 | todo | | |
| H3 | todo | | |
| M1 | todo | | |
| M2 | todo | | |
| M3 | todo | | |
| L1 | todo | | |
| L2 | todo | | |
| L3 | todo | | |

---

## 13) Related Work

- **Test Suite Koru-ification** — Parallel track to rewrite passing tests from Zig-heavy style to idiomatic Koru. Surfaces compiler gaps as a side effect. See `~/src/koru-audit/TEST_KORUIFICATION.md`.

---

## 14) Open Questions

- Do we make strict mode default for all non-interactive runs?
- Should we add an AST schema version to stabilize JSON snapshots?
- Do we want a dedicated parser fuzz suite or rely on regression growth?

