# DX Improvement Opportunities

Captured from 2026-01-30 session (Orisha SubflowImpl work).

## 1. SubflowImpl vs Call Confusion (Parser)

**Problem**: `~serve(port: port)` looks like a SubflowImpl but is actually a toplevel call. When `port` is undefined in library scope, the error is confusing.

**Fix**: Parser/emitter should detect when a toplevel flow references undefined variables and give a clearer error: "Did you mean to use SubflowImpl syntax? `~serve = ...`"

## 2. Terminal `_` on Non-Void Branches (Flow Checker) ⚠️ ALARMING

**Problem**: `| failed _ |> _` compiled but generated Zig code with no return statement, causing backend compile error.

**Fix**: Flow checker should verify that SubflowImpl branches either:
- Return a branch constructor for the parent event, OR
- Propagate to another flow that does

This is a type-level issue - the flow checker knows the event's Output type.

## 3. Debug Output Noise (Compiler)

**Problem**: Running compiled binary shows tons of `[TEST]`, `[PHASE]`, `[BUFFER DEBUG]` output, burying actual program output.

**Fix**: Gate debug output behind `--verbose` or `KORU_DEBUG=1` env var. Release builds should be quiet.

## 4. MUST_FAIL Test Hints (Test Runner)

**Problem**: When creating a MUST_FAIL test, I didn't know about the `EXPECT` file. Test passed when it shouldn't have.

**Fix**: Test runner could hint: "MUST_FAIL test compiled successfully. Did you mean to add `EXPECT` file with `FRONTEND_COMPILE_ERROR`?"

---

## Priority

1. **#2 (Flow Checker)** - This is a correctness bug, should be highest priority
2. **#3 (Debug Noise)** - Affects usability significantly
3. **#1 (Parser Error)** - Would have saved debugging time
4. **#4 (Test Hints)** - Nice to have
