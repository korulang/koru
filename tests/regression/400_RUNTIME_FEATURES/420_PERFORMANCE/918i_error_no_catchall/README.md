# Test 918i: Optional Branches - Runtime Error Without `|?`

## What This Test Verifies

This test demonstrates what happens when:
1. An optional branch **fires at runtime**
2. Handler has **no explicit handler** for that branch
3. Handler has **no `|?` catch-all**

**Expected behavior**: Runtime error (panic/crash).

## The Scenario

```koru
~event process { value: u32 }
| success { result: u32 }        // REQUIRED
| ?warning { msg: []const u8 }   // OPTIONAL

~proc process {
    if (value > 100) {
        return .{ .warning = .{ .msg = "Too large" } };  // Optional branch fires
    }
    return .{ .success = .{ .result = value * 2 } };
}

~process(value: 150)
| success { result } |> handle(result)  // Has success handler
// NO warning handler
// NO |? catch-all
// warning branch fires at runtime → ERROR!
```

## Why Is This A Runtime Error?

**Option 1: Compile Error**
- Pro: Catches problem early
- Con: Handler is technically valid (all REQUIRED branches handled)
- Con: Can't know at compile time which branch will fire
- Con: Would prevent valid programs (proc never returns optional branch in practice)

**Option 2: Runtime Error (panic)**
- Pro: Handler is valid (all required branches handled)
- Pro: Error only occurs if problematic path is taken
- Pro: Consistent with "branch interface must be satisfied"
- Con: Crashes at runtime instead of compile time

**This test assumes Option 2**: Valid at compile time, runtime panic if optional branch fires.

## The Design Question

Should the compiler:

**A) Require `|?` for any event with optional branches?**
- Pro: Prevents runtime errors
- Con: Forces boilerplate even if optional branches never fire

**B) Allow omitting `|?`, panic if unhandled optional branch fires?**
- Pro: More flexible, no boilerplate
- Con: Runtime errors possible

**C) Require either explicit handling OR `|?` for optional branches that CAN fire?**
- Pro: Best of both worlds
- Con: Requires flow analysis to determine which branches can fire

**This test documents current behavior** (likely Option B).

## Test Structure

```koru
~event process { value: u32 }
| success { result: u32 }
| ?warning { msg: []const u8 }

~proc process {
    if (value > 100) {
        return .{ .warning = .{ .msg = "Too large" } };
    }
    return .{ .success = .{ .result = value * 2 } };
}

// Call that returns success - works fine
~process(value: 10)
| success { result } |> print("Success: {}", .{result})
// No |? needed because warning never fires

// Call that returns warning - RUNTIME ERROR
~process(value: 150)
| success { result } |> print("Success: {}", .{result})
// No |? → warning fires → no handler → PANIC
```

## Expected Behavior

**First call** (value: 10):
- Returns `success` branch
- Handler has `success` continuation
- Executes successfully

**Second call** (value: 150):
- Returns `warning` branch
- Handler has NO `warning` continuation
- Handler has NO `|?` catch-all
- Branch interface cannot be satisfied
- **Runtime panic/error**

## Test Coverage

Part of comprehensive optional branches test suite:
- **Test 918**: Basic `|?` catch-all pattern
- **Test 918b**: Mix explicit handling + `|?` catch-all
- **Test 918d**: Shape validation (negative test)
- **Test 918e**: All optional + only `|?` (edge case)
- **Test 918f**: API evolution (anti-F# discard)
- **Test 918g**: `when` guards + `|?` interaction
- **Test 918h**: Event pump loop pattern (THE USE CASE)
- **Test 918i** (this): Error case without `|?` ← Runtime behavior!

## Files

- `input.kz` - Handler without `|?`, optional branch fires
- `EXPECT` - Should contain `RUNTIME_ERROR` or `RUNTIME_PANIC`
- `MUST_RUN` - Requires execution to verify runtime behavior
- `README.md` - This file

## Open Questions

1. Should this be compile error or runtime error?
2. If runtime error, what's the error message?
3. Should compiler warn if optional branches exist but no `|?`?
4. Should flow analysis determine if optional branches can fire?
