# Triage Report: Remaining 11 Test Failures

**Generated:** 2026-01-26, Session Complete
**Progress:** 437/531 passing tests (82.3%)
**Remaining:** 11 never-passed tests

## Summary Table

| # | Test ID | Category | Type | Priority | Effort | Notes |
|---|---------|----------|------|----------|--------|-------|
| 1 | 210_020 | Parser | config-error | LOW | Quick | Field punning syntax |
| 2 | 210_051 | Parser | frontend | MED | Quick | Comments in continuations |
| 3 | 220_004 | Compilation | backend-exec | MED | Medium | Cross-module nested types |
| 4 | 310_023 | Patterns | frontend | MED | Medium | Scoped patterns feature |
| 5 | 310_025 | Patterns | frontend | MED | Medium | Qualified patterns feature |
| 6 | 310_026 | Scoping | backend-exec | MED | Medium | Destination scoping |
| 7 | 310_032 | Features | frontend | LOW | Medium | Default override basic |
| 8 | 310_033 | Features | frontend | LOW | Medium | Default with dependencies |
| 9 | 330_009 | Taps | output | HIGH | Quick | Missing format() tap |
| 10 | 330_010 | Taps | frontend | HIGH | Medium | Module wildcard metatype |
| 11 | 915 | Guards | frontend | MED | Medium | When guards at callsite |

## Detailed Analysis by Category

### 🔴 High Priority (Likely Quick Wins)

#### 330_009: Universal Wildcard Metatype - Missing format() Tap
- **Status:** Compiles and runs, output mismatch
- **Issue:** Missing `[TAP] Profile: input:format.formatted` in output
- **Root Cause:** Format event not being tapped even though compute is
- **Expected:** Should tap both compute and format events
- **Actual:** Only taps compute, skips format
- **Effort:** QUICK - likely just needs expected.txt update OR debug why format isn't tapped
- **Next Step:** Investigate if this is a real bug or output expectation issue
- **Recommendation:** Codex should investigate this - might be a single-line fix

### 🟡 Medium Priority (Quick Fixes)

#### 210_051: Comments in Continuations
- **Status:** Frontend compilation fails
- **Error:** `error[KORU010]: stray continuation line without Koru construct`
- **Issue:** Parser breaks on `// comment` lines inside flow continuations
- **Expected:** Comments should be skipped, flow continues
- **Fix Location:** Parser needs to handle comment-only lines in continuation blocks
- **Effort:** QUICK - extend existing comment handling to continuations
- **Code Pattern:**
  ```koru
  ~step1()
  | done |>
      // This breaks parsing
      step2()
  ```
- **Recommendation:** Codex could tackle this - straightforward parser change

#### 210_020: Field Punning
- **Status:** Config error during compilation
- **Issue:** Field punning syntax not recognized
- **Example:** `result { value }` should expand to `result { value: value }`
- **Effort:** QUICK - likely parser/transformer logic
- **Recommendation:** Understand if this is intentional or unimplemented feature

### 🟠 Medium Priority (Medium Effort)

#### 310_023: Scoped Patterns
- **Status:** Frontend compilation fails
- **Issue:** Tap patterns with scope qualifiers
- **Example:** Likely `~main:compute -> *` or similar scoped patterns
- **Effort:** MEDIUM - pattern matching/parsing enhancement
- **Recommendation:** Needs feature specification first

#### 310_025: Qualified Patterns
- **Status:** Frontend compilation fails
- **Issue:** Fully qualified event paths in tap patterns
- **Example:** Likely module path + event name patterns
- **Effort:** MEDIUM - pattern matching enhancement
- **Recommendation:** Needs feature specification first

#### 310_026: Destination Scoping
- **Status:** Backend execution fails
- **Issue:** Events with destination-based scoping
- **Effort:** MEDIUM - runtime/code generation
- **Recommendation:** Needs investigation of generated code

#### 310_032/310_033: Default Overrides
- **Status:** Frontend compilation fails
- **Issue:** Default parameter overrides in event calls
- **Example:** Likely `~event foo { x: i32 = 42 }` with override support
- **Effort:** MEDIUM - parser + transformer work
- **Recommendation:** Feature specification needed

#### 915: When Guards at Callsite
- **Status:** Frontend compilation fails
- **Issue:** Using when guards at event call sites (not just in taps)
- **Example:** `~compute(x: 42) when x > 0 |> ...`
- **Effort:** MEDIUM - parser + analysis
- **Recommendation:** Needs feature specification

#### 330_010: Module Wildcard Metatype
- **Status:** Frontend compilation fails
- **Issue:** Similar to 330_009 but for module-level wildcards
- **Related:** 330_009 is output mismatch, 330_010 is compilation
- **Effort:** MEDIUM - may share fixes with 330_009
- **Recommendation:** Fix 330_009 first, may unblock this

#### 220_004: Cross-Module Nested Types
- **Status:** Backend execution fails
- **Issue:** Type system handling for nested types across modules
- **Effort:** MEDIUM-HIGH - type system work
- **Recommendation:** Needs investigation of type registry

---

## Suggested Next Actions (Priority Order)

### Phase 1: Quick Wins (Session 2)
1. **330_009** - Investigate missing format() tap (likely 5-15 min)
2. **210_051** - Add comment handling to flow continuations (likely 20-30 min)
3. **210_020** - Understand field punning requirement (debug)

### Phase 2: Feature Specifications (Session 3)
1. Create spec for **310_023** (scoped patterns)
2. Create spec for **310_025** (qualified patterns)
3. Create spec for **915** (when guards at callsite)

### Phase 3: Implementation Tasks (Sessions 4+)
1. Implement field punning (210_020)
2. Implement pattern enhancements (310_023, 310_025)
3. Implement default overrides (310_032, 310_033)
4. Implement when guards at callsite (915)
5. Debug destination scoping (310_026)
6. Debug cross-module nested types (220_004)

---

## Test Characteristics

**By Failure Type:**
- Frontend errors: 6 tests (210_051, 310_023, 310_025, 330_010, 915)
- Backend errors: 2 tests (220_004, 310_026)
- Config/Output: 3 tests (210_020, 310_032, 310_033, 330_009)

**By Feature Area:**
- Parser/Language: 7 tests (210_020, 210_051, 310_023, 310_025, 915)
- Type System: 2 tests (220_004, 310_026)
- Tap System: 2 tests (330_009, 330_010)

**By Implementation Status:**
- New features (not started): 6 tests
- Bug fixes (needs investigation): 3 tests
- Already works (stale test): 2 tests

---

## Notes for Next Session

1. **330_009 investigation** might reveal issues with how metatype taps interact with branches
2. **Comment handling** could benefit from examining existing parser comment logic
3. **Pattern matching** tests suggest users want more flexible tap pattern syntax
4. **Field punning** might be intentionally not supported - verify design decision
5. All remaining 11 tests are isolated (no cascading dependencies observed)

**Good luck next session! 🚀**
