# Compiler Single-Empty-Branch Migration — Current State

**Status:** 542/579 in-scope passing (93.6%) as of snapshot 5/5/2026, 2:57:45 PM

**Running:** Full regression suite is currently executing in the background. Do NOT start another run or edit stdlib/tests until it completes.

---

## The Compiler Change

The parser now **rejects events with a single empty branch and no payload**.

```
// ILLEGAL — will error
event done:
  | done

// LEGAL — void event (0 branches)
event done:

// LEGAL — event with a typed payload
event done:
  | done i32
```

This rule is correct: a single branch with no fields and no `plain_value` carries zero information, so it should be a void event instead.

**Consequence:** Every stdlib file that declares `| branch` with no payload is now broken. The compiler is right; the stdlib must migrate.

---

## What We Already Fixed

### Phantom type tests (identity branch syntax migration)
- `330_008`, `330_018`, `330_051`, `330_052`, `330_056`, `350_002`
- Root cause: tests still used `f.file` / `h1.h` / `c.r` field access after branches became identity types (`__type_ref`)
- Compiler fixes in `phantom_semantic_checker.zig` and `auto_discharge_inserter.zig` to handle `plain_value` in branch constructors

### AST mismatch tests (stale expected.json)
- `052_lenient_multiple_errors`, `100_080_nested_when_guards`
- Regenerated `expected.json` after identity syntax changed field names to `__type_ref`

### Parser negative tests
- `210_062_reject_empty_brace_payload` — fixed test input
- `210_063_reject_single_field_braces` — fixed test input
- `510_015` — fixed

### Archive exclusion
- `_archive/` directories under `910_LANGUAGE_SHOOTOUT/` are now excluded from the harness (`run_regression.sh`, `generate-status.js`, `save-snapshot.js`)
- Stale FAILURE/SUCCESS markers cleaned from `_archive/`

### Stdlib (partial)
- `koru_std/compiler_types.kz` — removed `| done` from `__compiler_types_marker`
- `koru_std/testing.kz` — removed `| failed` from `assert.fail`

### Regression threshold
- Bumped from 48h to 30 days in `scripts/show-regressions.js`

---

## What Still Needs Migration

### Stdlib files with single empty branches (broken by new parser rule)

These all declare `| branch` with no payload and must become void events:

- [ ] `koru_std/simple.kz` — `| done`
- [ ] `koru_std/fmt.kz` — `| done`
- [ ] `koru_std/io.kz` — `| eof`, `| printed`, `| not_found`
- [ ] `koru_std/net.kz` — `| closed`
- [ ] `koru_std/http.kz` — `| no_match`
- [ ] `koru_std/args.kz`
- [ ] `koru_std/threading.kz`
- [ ] `koru_std/json.kz`
- [ ] `koru_std/eval.kz`
- [ ] `koru_std/rings.kz`
- [ ] `koru_std/string.kz`
- [ ] `koru_std/inter.kz`
- [ ] `koru_std/env.kz`
- [ ] `koru_std/ccp.kz`
- [ ] `koru_std/runtime.kz`
- [ ] `koru_std/runtime_control.kz`

**Migration pattern:**
```
// Before (broken)
event done:
  | done

// After (void event)
event done:
```

**Any test that continues on these events** must also change:
```
// Before
| done |> _

// After (void event — no branch to match)
|> _
```

### Remaining 26 failures (not caused by single-empty-branch rule)

These are backend / runtime / purity issues and should be investigated separately:

- **210_024** `source_scope_capture` (backend-exec)
- **220_022** `combined_continuation_bugs` (backend-exec)
- **370_021** `label_jump_scope_outer_ok` (timeout-30s)
- **390_052/053** `reject_user/stdlib_event_in_kernel` (backend-exec)
- **410_001/003/004/006/007/008** — purity checking (backend-exec)
- **430_001/009/011/011/025/035/036/037/038/039/040/041/050/052** — runtime/coordination/interpreter (backend/backend-exec)
- **440_002** `cross_session_discharge` (backend-exec)

---

## Next Steps

1. **Wait for the current `run_regression.sh` to finish.**
2. **Migrate stdlib single-empty-branches** in the files listed above.
3. **Update any tests** that `continue` on those events (remove `| branch` pattern, use bare `|> _` for void events).
4. **Re-run the regression suite.**
5. **Triage the 26 backend/runtime failures** separately.

---

## Key Principle

The compiler is correct. Do NOT weaken the parser to make stdlib/tests pass. Migrate the stdlib and tests to match the compiler's rules.
