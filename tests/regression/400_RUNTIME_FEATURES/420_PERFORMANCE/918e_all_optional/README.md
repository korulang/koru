# Test 918e: Optional Branches - All Optional with `|?` Only (EDGE CASE)

## What This Test Verifies

This test verifies the **extreme edge case**: an event with NO required branches and a handler with ONLY `|?` (no explicit branch handling).

**Specific test case**:
- Event has 3 branches, ALL optional (zero required)
- Handler has NO explicit branch handlers, ONLY `|?` catch-all

## Why This Edge Case Matters

This tests whether the system accepts:
- Zero required branches in event declaration
- Zero explicit branch handlers (only `|?`)
- The combination of both

**Question for implementation**: Is a handler with ONLY `|?` and no explicit branches valid?

```koru
~event process { value: u32 }
| ?success { result: u32 }    // ALL
| ?warning { msg: []const u8 } // OPTIONAL
| ?error { msg: []const u8 }   // ZERO REQUIRED

~process(value: 10)
|? |> handle_any()  // Valid? No explicit branches, only |?
```

## Edge Cases Tested

1. ✅ Compiler accepts event with zero required branches
2. ✅ Proc can return any of the optional branches
3. ✅ Handler with ONLY `|?` (no explicit branches) is valid
4. ✅ Code generation works with only catch-all handler
5. ✅ Execution works correctly for all code paths

## Test Behavior

Three executions hitting different optional branches:
- **value: 10** → `success` branch → Caught by `|?` → "Optional branch fired"
- **value: 150** → `warning` branch → Caught by `|?` → "Optional branch fired"
- **value: 0** → `error` branch → Caught by `|?` → "Optional branch fired"

All branches flow through `|?` catch-all. All executions succeed.

## Potential Issues This Could Catch

- Shape checker requires at least one explicit branch handler
- Code generator breaks with only catch-all, no explicit branches
- Handler validation fails when zero required + zero explicit branches
- Runtime flow routing fails with only `|?`

## Is This Pattern Realistic?

Questionable real-world use, but tests edge case constraints:

**More realistic**: All-optional event with some explicit handling:
```koru
~event log {}
| ?info { msg: []const u8 }
| ?warn { msg: []const u8 }
| ?error { msg: []const u8 }

~log()
| error { msg } |> handle_error(msg)  // Care about errors
|? |> continue                        // Ignore info/warn
```

**This test (only |?)**: Valid for "fire and forget" event handling where you don't care about specifics.

## Test Coverage

Part of comprehensive optional branches test suite:
- **Test 918**: Basic `|?` catch-all pattern
- **Test 918b**: Mix explicit handling + `|?` catch-all
- **Test 918d**: Shape validation (negative test)
- **Test 918e** (this): All optional + only `|?` ← Extreme edge case!
- **Test 918f**: API evolution (required vs optional branches)
- **Test 918g**: `when` guards + `|?` interaction
- **Test 918h**: Event pump loop pattern (THE USE CASE)
- **Test 918i**: Error case without `|?` (runtime behavior)

## Files

- `input.kz` - Event with only optional branches, handler with only `|?`
- `expected.txt` - All branches caught by `|?`
- `MUST_RUN` - Requires execution
- `README.md` - This file
