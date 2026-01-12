# PLAN: Continuation & Obligation Bugs

**Status:** Draft
**Created:** 2026-01-12
**Priority:** CRITICAL - blocks signature Koru syntax

## Problem Summary

Four bugs prevent natural Koru flow patterns. **Two are emitter bugs, one is escape checker, one is parser.**

| Bug | Test | Component | Status |
|-----|------|-----------|--------|
| Void event chaining | `220_021` | **EMITTER** | TODO |
| Nested branch shadowing | `220_020` | **EMITTER** | TODO |
| Escape field name mismatch | `330_052` | **ESCAPE CHECKER** | **FIXED** (2026-01-12) |
| Void chaining syntax | (new) | **PARSER** | TODO |

## Why These Matter

**Without fixes, users must write:**
```koru
work(r: r.r)
| done |>
    work(r: r.r)
    | done |>
        destroy(r: r.r)
```

**With fixes, users can write:**
```koru
work(r.r) |> work(r.r) |> destroy(r.r)
```

This is the difference between "awkward" and "beautiful".

## Root Cause Hypothesis

All three bugs likely stem from how `emitContinuation` handles:
1. **Void returns** - tries to switch on void instead of just sequencing
2. **Binding names** - uses literal branch names for Zig variables
3. **Escape tracking** - matches by string name instead of value identity

## Investigation Plan

### Phase 1: Understand Current Behavior
- [ ] Read `visitor_emitter.zig` focusing on `emitContinuation` and related
- [ ] Trace code path for void event → identify where switch is generated
- [ ] Trace code path for nested branches → identify where binding names come from
- [ ] Trace escape checker → identify where field name matching happens

### Phase 2: Design Fix
- [ ] For void: detect void Output type, emit sequential calls not switch
- [ ] For shadowing: generate unique binding names (e.g., `done_0`, `done_1`)
- [ ] For escape: track by value/pointer, not field name string

### Phase 3: Implement & Test
- [ ] Create combined test file that exercises ALL THREE patterns
- [ ] Fix void chaining first (most impactful)
- [ ] Fix shadowing second (likely same area of code)
- [ ] Fix escape matching (may be in different file - escape_checker.zig?)
- [ ] Run combined test after each fix to catch regressions

## Test Strategy

**Combined regression test:** Create a single test that uses:
- Void events in a chain
- Same branch names at multiple nesting levels
- Obligation escape with different field names

If this test passes, all three bugs are fixed without whack-a-mole.

## Files to Investigate

```
src/visitor_emitter.zig    - Emitter bugs (void switch, shadowing)
src/phantom_checker.zig    - Escape field name bug (KORU030 error)
src/parser.zig             - Void chaining syntax
```

## Combined Test

`tests/regression/200_COMPILER_FEATURES/220_COMPILATION/220_022_combined_continuation_bugs/input.kz`

This test exercises bugs #2 and #3 together. When both pass, run the benchmark syntax test.

## Success Criteria

The benchmark code compiles with clean syntax:
```koru
~for(0..N)
| each i |>
    create(id: i)
    | created r |>
        work(r.r) |> work(r.r) |> work(r.r) |> work(r.r) |> work(r.r)
```

No explicit `| done |>` chains. No explicit `destroy`. Just flow.

## Notes

- Full test suite takes ~15 minutes - use targeted tests during development
- These bugs are in the emitter, not parser - AST is correct
- Zig native backend (non-LLVM) coming soon - will speed up iteration
