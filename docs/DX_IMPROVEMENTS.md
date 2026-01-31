# DX Improvement Opportunities

Captured from 2026-01-30 session (Orisha SubflowImpl work).

---

## ✅ RESOLVED (2026-01-31)

### Debug Output Noise - FIXED

**Was**: Running compiler showed 244 lines of `debug(module_resolver)` noise before showing actual error.

**Fix**: Migrated 4 files from `std.log.scoped()` to custom `log.zig` system:
- `src/module_resolver.zig`
- `src/config.zig`
- `src/type_registry.zig`
- `src/ast_serializer.zig`

**Result**: Clean 6-line error output:
```
error[PARSE004]: unmatched '{' in event shape
  --> input.kz:5:0
  |
  5 | ~event write {
  | ^
```

### Error Message Documentation - NEW

**Added**: `expected.txt` support for negative tests. Test harness now:
- Exact-matches compiler error output against `expected.txt`
- Falls back to legacy substring match if no `expected.txt`
- Shows diff on mismatch

**Result**: Error messages automatically appear on korulang.org via `lessons.json`.

**Documented so far**:
- `510_001`: `error[PARSE004]: unmatched '{' in event shape`
- `510_002`: `error[PARSE004]: unmatched '{' in branch payload shape`
- `510_005`: `error[PARSE003]: event declaration missing name`

---

## Outstanding Issues

### 1. SubflowImpl vs Call Confusion (Parser)

**Problem**: `~serve(port: port)` looks like a SubflowImpl but is actually a toplevel call. When `port` is undefined in library scope, the error is confusing.

**Fix**: Parser/emitter should detect when a toplevel flow references undefined variables and give a clearer error: "Did you mean to use SubflowImpl syntax? `~serve = ...`"

### 2. Terminal `_` on Non-Void Branches (Flow Checker) ⚠️ ALARMING

**Problem**: `| failed _ |> _` compiled but generated Zig code with no return statement, causing backend compile error.

**Fix**: Flow checker should verify that SubflowImpl branches either:
- Return a branch constructor for the parent event, OR
- Propagate to another flow that does

This is a type-level issue - the flow checker knows the event's Output type.

### 3. ~~Debug Output Noise (Compiler)~~ ✅ FIXED

See "RESOLVED" section above.

### 4. MUST_FAIL Test Hints (Test Runner)

**Problem**: When creating a MUST_FAIL test, I didn't know about the `EXPECT` file. Test passed when it shouldn't have.

**Fix**: Test runner could hint: "MUST_FAIL test compiled successfully. Did you mean to add `EXPECT` file with `FRONTEND_COMPILE_ERROR`?"

### 5. Stack Traces Instead of Clean Errors (Error Handling) - NEW

**Problem**: Some errors produce Zig stack traces instead of clean error messages:
```
error: ModuleNotFound
/Users/.../module_resolver.zig:392:17: 0x104b8c2ff in resolveBoth (koruc)
    return error.ModuleNotFound;
    ^
```

**Affected tests**: `510_012_multiple_defaults_error`, `510_013_ambiguous_override_error`

**Fix**: These should produce clean errors like:
```
error[RESOLVE001]: module 'nonexistent' not found
  --> input.kz:1:8
```

### 6. Parallel Test Runner Reporting (Test Harness) - NEW

**Problem**: When running tests in parallel, failure count doesn't match actual failures in log output. Some failures may be lost in collection.

**Fix**: Investigate `run_regression.sh --parallel` output aggregation.

---

## Priority

1. **#2 (Flow Checker)** - Correctness bug, highest priority
2. **#5 (Stack Traces)** - Produces unusable error output
3. **#1 (Parser Error)** - Would save debugging time
4. **#4 (Test Hints)** - Nice to have
5. **#6 (Parallel Runner)** - Tooling issue, low priority
