# Test 918: Optional Branches - Basic `|?` Catch-All

## What This Test Verifies

This test verifies the fundamental optional branches pattern with `|?` catch-all:

1. **Events can declare optional branches** using `?` prefix
2. **Handlers use `|?` to catch all optional branches generically**
3. **Execution continues when optional branches fire** (caught by `|?`)

## The Design

### Event Declaration

Optional branches allow event designers to mark certain branches as non-essential:

```koru
~event process { value: u32 }
| success { result: u32 }        // REQUIRED: must be handled explicitly
| ?warning { msg: []const u8 }   // OPTIONAL: can be caught by |?
| ?debug { details: []const u8 } // OPTIONAL: can be caught by |?
```

### Handler with `|?` Catch-All

Handlers use `|?` to catch all optional branches generically:

```koru
~process(value: 10)
| success { result } |> handle(result)      // Explicit handling
|? |> std.debug.print("Optional branch\n", .{})  // Catches warning, debug, etc.
```

**Key insight**: Without `|?`, if an optional branch fires, execution stops (branch interface not satisfied). The `|?` catch-all satisfies the interface for all optional branches.

## Why `|?` Is NOT the F# Discard Pattern

This is fundamentally different from F#'s `_` discard:

**F# discard problem:**
```fsharp
match x with
| Case1 -> handle1()
| Case2 -> handle2()
| _ -> default()  // SILENTLY accepts future cases - BAD!
```

When you add `Case3`, the `_` silently catches it. No compile error. This violates Koru's principle: **cascade compilation errors are how you evolve APIs**.

**Koru's `|?` is different:**

- Adding a **REQUIRED** branch → **compile error** on all handlers without that branch
- Adding an **OPTIONAL** branch → silently caught by `|?` (correct! it's optional)
- `|?` catches optional branches ONLY, not required branches
- Required branches always force explicit handling

## Test Behavior

This test calls `~process()` three times:

1. **value: 10** (even, < 100) → Returns `success` → Handled explicitly → Prints "Success: 20" then "Got success: 20"
2. **value: 150** (> 100) → Returns `warning` → Caught by `|?` → Prints "Got optional branch"
3. **value: 7** (odd) → Returns `debug` → Caught by `|?` → Prints "Got optional branch"

All three calls complete successfully. Execution continues after each call.

## Test Coverage

This test is part of a comprehensive suite:
- **Test 918** (this): Basic `|?` catch-all pattern
- **Test 918b**: Mix explicit handling + `|?` catch-all
- **Test 918d**: Shape validation (negative test - wrong payload type)
- **Test 918e**: All-optional events (edge case - zero required branches)
- **Test 918f**: API evolution (required vs optional branches)
- **Test 918g**: `when` guards + `|?` interaction
- **Test 918h**: Event pump loop pattern (THE USE CASE)
- **Test 918i**: Error case without `|?` (runtime behavior)

## Files in This Test

- `input.kz` - Test case demonstrating basic `|?` catch-all
- `expected.txt` - Expected output showing all three calls succeed
- `MUST_RUN` - Requires execution to verify behavior
- `README.md` - This file
