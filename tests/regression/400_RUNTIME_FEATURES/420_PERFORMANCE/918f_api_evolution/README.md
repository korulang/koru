# Test 918f: Optional Branches - API Evolution (Anti-F# Discard)

## What This Test Verifies

This test demonstrates **why `|?` is NOT the F# discard pattern** through API evolution scenarios.

**Core principle**: Cascade compilation errors are HOW you evolve APIs in Koru.

## The F# Discard Problem

In F#, the `_` discard silently accepts future cases:

```fsharp
match result with
| Success x -> handle_success(x)
| Error e -> handle_error(e)
| _ -> default()  // SILENTLY catches future cases
```

When you add `Timeout` to the union:
- **NO COMPILE ERROR** - the `_` silently catches it
- You never consider whether `Timeout` needs special handling
- This violates the principle of exhaustive handling

## Koru's `|?` Is Different

```koru
~event process {}
| success { result: u32 }        // REQUIRED
| ?warning { msg: []const u8 }   // OPTIONAL

~process()
| success { result } |> handle(result)  // Required
|? |> continue                          // Optional catch-all
```

### Scenario 1: Adding a REQUIRED Branch

Add a new REQUIRED branch to the event:
```koru
| error { msg: []const u8 }  // NEW REQUIRED BRANCH
```

**Result**: COMPILE ERROR on ALL handlers without `error` continuation.

**Why this is good**: Forces you to consider error handling everywhere. Cascade compilation errors ensure complete API evolution.

### Scenario 2: Adding an OPTIONAL Branch

Add a new OPTIONAL branch to the event:
```koru
| ?debug { info: []const u8 }  // NEW OPTIONAL BRANCH
```

**Result**: NO COMPILE ERROR. Silently caught by `|?`.

**Why this is good**: Optional branches are supplementary information. Handlers that don't care about debug info can continue using `|?`. Handlers that DO care can add explicit handling.

## The Key Difference

**F# discard (`_`)**:
- Catches EVERYTHING (including future important cases)
- Breaks exhaustive handling
- Silently accepts breaking changes

**Koru catch-all (`|?`)**:
- Catches OPTIONAL branches ONLY
- Preserves exhaustive handling for required branches
- Only accepts supplementary information

## Test Structure

This test demonstrates Scenario 2 (adding optional branch):

**Version 1 (initial)**:
```koru
~event process { value: u32 }
| success { result: u32 }
| ?warning { msg: []const u8 }
```

**Version 2 (add optional branch)**:
```koru
~event process { value: u32 }
| success { result: u32 }
| ?warning { msg: []const u8 }
| ?debug { info: []const u8 }    // NEW OPTIONAL BRANCH
```

**Handlers from Version 1 still work without modification**:
```koru
~process(value: 10)
| success { result } |> handle(result)
|? |> continue  // Silently catches new 'debug' branch
```

This is CORRECT behavior because `debug` is OPTIONAL - handlers that don't care don't need to change.

## What About Required Branches?

For demonstrating that adding REQUIRED branches causes compile errors, see:
- Test 918d (shape validation errors)
- Or try removing the `success` handler from this test - it will fail!

The shape checker enforces that ALL required branches must have handlers. Optional branches can use `|?`.

## Test Coverage

Part of comprehensive optional branches test suite:
- **Test 918**: Basic `|?` catch-all pattern
- **Test 918b**: Mix explicit handling + `|?` catch-all
- **Test 918d**: Shape validation (negative test)
- **Test 918e**: All optional + only `|?` (edge case)
- **Test 918f** (this): API evolution - adding optional branches doesn't break handlers
- **Test 918g**: `when` guards + `|?` interaction
- **Test 918h**: Event pump loop pattern (THE USE CASE)
- **Test 918i**: Error case without `|?` (runtime behavior)

## Files

- `input.kz` - Shows event with "evolved" optional branch, old handlers still work
- `expected.txt` - All handlers execute successfully
- `MUST_RUN` - Requires execution
- `README.md` - This file
