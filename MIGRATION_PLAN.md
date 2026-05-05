# Compiler Single-Empty-Branch Migration — Current State

**Status:** Parser rule is solid. `koru_std/io.kz` fixed. Hello World compiles.

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

// LEGAL — multiple empty branches (branching itself carries information)
event result:
  | ok
  | err
```

This rule is correct: a single branch with no fields and no `plain_value` carries zero information, so it should be a void event instead. Two or more empty branches are fine because the branching decision itself carries information.

**Consequence:** Every stdlib file that declares `| branch` with no payload is now broken. The compiler is right; the stdlib must migrate. **This is NOT a compiler bug.** The regression failures are stdlib violations being caught correctly.

---

## What We Already Fixed

### Parser rule (unit tested)
- Check at `src/parser.zig:1492` — rejects single empty branch with error `PARSE003`
- **4 unit tests added** to `src/parser.zig`:
  - `"parser rejects single empty branch as redundant"` — verifies ParseError + message
  - `"parser allows void event with zero branches"` — verifies clean compile
  - `"parser allows single identity branch with type payload"` — verifies `__type_ref`
  - `"parser allows two empty branches"` — verifies multiple empty branches are OK
- **Parser test suite:** 17/19 passing (up from 13/15), same 2 pre-existing failures

### Stdlib fixed
- `koru_std/io.kz` — `eprintln`, `success`, `warn` are now void events (removed `| printed`)
- `koru_std/compiler_types.kz` — `__compiler_types_marker` is now void
- `koru_std/testing.kz` — `assert.fail` is now void

### Test fixes
- `330_008`, `330_018`, `330_051`, `330_052`, `330_056`, `350_002` — phantom type identity syntax
- `052`, `100_080` — regenerated `expected.json`
- `210_062`, `210_063`, `510_015` — parser negative tests
- `_archive/` directories excluded from harness
- `tour/` directory deleted (old broken examples)

---

## What Still Needs Migration

### Stdlib files with single empty branches

These all declare `| branch` with no payload and must become void events:

- [x] `koru_std/io.kz` — `eprintln`, `success`, `warn` fixed
- [ ] `koru_std/simple.kz` — `| done`
- [ ] `koru_std/fmt.kz` — `| done`
- [ ] `koru_std/net.kz` — `| closed`
- [ ] `koru_std/http.kz` — `| no_match`
- [ ] `koru_std/args.kz` — `| out_of_bounds`
- [ ] `koru_std/threading.kz` — `| spawned`
- [ ] `koru_std/json.kz` — `| not_found`
- [ ] `koru_std/eval.kz` — `| null`, `| true`, `| false`
- [ ] `koru_std/rings.kz` — `| ok`, `| full`, `| none`
- [ ] `koru_std/string.kz` — `| ok`
- [ ] `koru_std/inter.kz` — `| launched`, `| skipped`
- [ ] `koru_std/env.kz` — `| not_set`, `| yes`, `| no`
- [ ] `koru_std/ccp.kz` — `| done`
- [ ] `koru_std/runtime.kz` — `| not_found`, `| collected`
- [ ] `koru_std/runtime_control.kz` — `| then`, `| else`

**Note:** Some events like `readln` have `| eof` alongside `| line` and `| failed` — these are fine because they have 3 branches total. Only events with **exactly one** empty branch are broken.

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

### Remaining backend/runtime failures (NOT caused by single-empty-branch rule)

These are separate issues and should be investigated separately:

- **210_024** `source_scope_capture` (backend-exec)
- **220_022** `combined_continuation_bugs` (backend-exec)
- **370_021** `label_jump_scope_outer_ok` (timeout-30s)
- **390_052/053** `reject_user/stdlib_event_in_kernel` (backend-exec)
- **410_001/003/004/006/007/008** — purity checking (backend-exec)
- **430_001/009/011/011/025/035/036/037/038/039/040/041/050/052** — runtime/coordination/interpreter (backend/backend-exec)
- **440_002** `cross_session_discharge` (backend-exec)

---

## Key Principle

The compiler is correct. Do NOT weaken the parser to make stdlib/tests pass. Migrate the stdlib and tests to match the compiler's rules.
