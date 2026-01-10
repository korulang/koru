# Task 001: Interpreter Runtime Test Fixes

## Status
- [ ] In Progress

## Overview

The runtime interpreter system allows Koru code to be parsed and executed at runtime - enabling Koru to be used as a wire protocol (replacing REST/GraphQL with continuation chains sent over HTTP). Several tests in the 430_ range are failing and need fixes.

## Failing Tests Summary

| Test | Failure Type | Issue |
|------|--------------|-------|
| 430_001 | Frontend | Invalid test syntax `\|> { block }` |
| 430_017 | Backend | Module conflict `ast` vs `ast0` |
| 430_018 | Backend | Module conflict `ast` vs `ast0` |
| 430_019 | Output | Expected `EventDenied`, got `EventNotFound` |
| 430_022 | Backend | Module conflict `ast` vs `ast0` |
| 430_025 | Backend | Incomplete branch coverage |

---

## Issue 1: Module Deduplication (CORE - affects 430_017, 430_018, 430_022)

### Problem

When a Koru program imports multiple standard library modules that share dependencies, Zig 0.15 fails with:

```
error: file exists in modules 'ast' and 'ast0'
note: files must belong to only one module
```

This happens because each `~std.build:requires` block independently adds its module imports, and when merged, the same file gets added under multiple module names.

### How Koru Build Works

1. Koru source files can include `~std.build:requires { ... }` blocks containing Zig build code
2. These blocks declare module dependencies needed at runtime
3. The compiler collects ALL `~std.build:requires` blocks from the program and imported std libraries
4. `backend.zig` generates `build_output.zig` which contains the merged build requirements
5. Zig's build system compiles the final executable with these modules

### Files to Examine

- `src/backend.zig` - Generates build files, look for build requirement handling
- `src/emitter.zig` - May handle build requirement collection
- `koru_std/interpreter.kz` - Has build:requires adding parser modules
- `koru_std/eval.kz` - Has build:requires adding ast modules

### Proposed Fix

When generating `build_output.zig`, deduplicate module imports:
1. Track which source files have already been added as modules
2. If a file is already imported under name X, reuse that reference
3. Don't create duplicate module definitions for the same file

---

## Issue 2: Invalid Test Syntax (430_001)

### Problem

Test uses `|> { ... }` bare block syntax which isn't valid Koru:

```koru
~parser:parse.source(source: test_source, ...)
| parsed p |> {
    std.debug.print("Parser works!");
}
```

The parser interprets `{ }` as a branch constructor with empty name.

### Error

```
error[PARSE003]: invalid branch name '' in constructor - must be a valid identifier
```

### Fix Options

1. **Rewrite test** to use proper Koru syntax (call an event instead of bare block)
2. **Mark as MUST_FAIL** if testing parser error handling

### File

- `tests/regression/400_RUNTIME_FEATURES/430_RUNTIME/430_001_parser_userland/input.kz`

---

## Issue 3: EventDenied vs EventNotFound (430_019)

### Problem

Test expects `EventDenied` error but dispatcher returns `EventNotFound`.

```
Expected: Dispatch result: EventDenied (handled specially)
Actual:   Dispatch result: EventNotFound (handled specially)
```

### Context

The dispatcher in `runtime.kz` returns `error.EventNotFound` when an event isn't in the registered scope. The test expected `error.EventDenied`.

### Fix Options

1. **Update expected.txt** to match current behavior (EventNotFound)
2. **Change dispatcher** to return EventDenied for unregistered events (semantic decision)

### Files

- `tests/regression/400_RUNTIME_FEATURES/430_RUNTIME/430_019_interpreter_if/expected.txt`
- `koru_std/runtime.kz` (line ~190 returns `error.EventDenied`)

---

## Issue 4: Incomplete Branch Coverage (430_025)

### Problem

Test was modified to use `~std.runtime:get_scope` event but doesn't handle all branches properly, causing compiler coordination error.

### Error

```
Compiler coordination error: Incomplete branch coverage
```

### Context

The test flow needs to handle both `| scope s |>` and `| not_found |>` branches from `get_scope`.

### File

- `tests/regression/400_RUNTIME_FEATURES/430_RUNTIME/430_025_interpreter_benchmark_real/input.kz`

---

## Current Benchmark Numbers (430_030_honest_benchmark)

Honest 3-step dispatch benchmark (add → multiply → subtract with string parsing):

| Language | Hyperfine Mean | Notes |
|----------|---------------|-------|
| **Koru** | **9.5ms** | 2.6x faster than Python |
| Python | 25.8ms | Includes interpreter startup |

This is the baseline for optimization work.

## Success Criteria

1. All 430_ tests pass: `./run_regression.sh 430`
2. No regressions in other test suites
3. Module deduplication works for any combination of std library imports

## Constraints

- Don't change `~std.build:requires` syntax or semantics
- Maintain backwards compatibility with existing Koru programs
- Solutions should not require users to change their code (except for genuinely broken tests)
