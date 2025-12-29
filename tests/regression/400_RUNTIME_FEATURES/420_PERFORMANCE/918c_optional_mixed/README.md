# Test 918c: Optional Branches - Mixed Usage (Selective Handling)

## What This Test Verifies

This test verifies that handlers can **selectively** handle optional branches - some handled, others completely ignored.

**Specific test case**: Event has 4 branches (1 required + 3 optional). Handler handles required + 1 optional, ignores 2 optional branches.

## Why This Matters

This is the most realistic use case for optional branches in practice:
- API designers add multiple optional branches for different use cases
- Each handler chooses which optional branches matter to it
- Shape checker must allow this selective handling

## Test Structure

```koru
~event analyze { value: u32 }
| success { result: u32 }         // REQUIRED
| ?warning { msg: []const u8 }    // OPTIONAL - handler uses this
| ?debug { info: []const u8 }     // OPTIONAL - handler ignores this
| ?trace { details: []const u8 }  // OPTIONAL - handler ignores this

// Proc can return ANY of these branches
~proc analyze {
    if (value == 0) return .{ .debug = ... };    // Handler doesn't handle this
    if (value == 1) return .{ .trace = ... };    // Handler doesn't handle this
    if (value > 100) return .{ .warning = ... }; // Handler handles this
    return .{ .success = ... };                   // Handler handles this
}

// Handler is selective
~analyze(value: 50)
| success |> ...
| warning |> ...
// NO continuations for debug or trace - totally fine!
```

## Key Verification Points

1. ✅ Shape checker allows handler with only `success` + `warning` continuations
2. ✅ No error even though `debug` and `trace` are not handled
3. ✅ When proc returns `debug` or `trace`, ??? (behavior undefined for now)
4. ✅ When proc returns `success` or `warning`, handler works correctly

## Note on Unhandled Branches

When the proc returns an unhandled optional branch (like `debug` or `trace` in this test), the behavior is currently undefined. This is okay because:
- The proc COULD return these branches
- But in THIS test execution, the values are chosen so those paths aren't hit
- Future optimization (Phase 4) would eliminate that dead code

## Expected Behavior

- First call (value=50): success path, prints "Success: 100"
- Second call (value=150): warning path, prints "Warning: Large value"

Note: We deliberately avoid value=0 or value=1 which would hit debug/trace branches.

## Test Coverage

Part of comprehensive optional branches test suite:
- **Test 918**: Handlers OMIT all optional branches
- **Test 918b**: Handlers HANDLE all optional branches
- **Test 918c** (this): Mixed - some handled, some not ← Real-world!
- **Test 918d**: Shape validation (negative test)
- **Test 918e**: All-optional events (edge case)

## Files

- `input.kz` - Test case with selective handling
- `expected.txt` - Success and warning outputs
- `MUST_RUN` - Requires execution
- `README.md` - This file
