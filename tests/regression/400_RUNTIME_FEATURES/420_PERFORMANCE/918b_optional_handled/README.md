# Test 918b: Optional Branches - Mix Explicit Handling + `|?` Catch-All

## What This Test Verifies

This test demonstrates the **most realistic real-world pattern**: mixing explicit handling of specific optional branches with `|?` catch-all for the rest.

**Pattern tested**:
- Event has multiple optional branches
- Handler explicitly handles some optional branches (the ones it cares about)
- Handler uses `|?` to catch remaining optional branches (the ones it doesn't care about)

## Why This Pattern Matters

This is how optional branches will be used in practice:

```koru
~event pump {}
| ?mouse_event { code: i32 }     // I care about mouse events
| ?keyboard_event { code: i32 }   // I care about keyboard events
| ?window_event { code: i32 }    // I DON'T care about window events
| ?timer_event { code: i32 }     // I DON'T care about timer events
// ... 50 other event types

~pump()
| mouse_event { code } |> handle_mouse(code)      // Explicit
| keyboard_event { code } |> handle_keyboard(code) // Explicit
|? |> continue                                     // Everything else
```

Without this pattern, you'd need exhaustive handling of ALL optional branches, which defeats the purpose of optional branches.

## Test Structure

```koru
~event process { value: u32 }
| success { result: u32 }        // REQUIRED
| ?warning { msg: []const u8 }   // Handled explicitly
| ?debug { info: []const u8 }    // Caught by |?
| ?trace { details: []const u8 } // Caught by |?

~process(value: X)
| success { result } |> handle_success(result)  // Required
| warning { msg } |> handle_warning(msg)        // We care about warnings
|? |> continue                                  // Ignore debug/trace
```

## Test Behavior

Four calls demonstrate all code paths:

1. **value: 10** → `success` → Explicit handling → "Success: 20"
2. **value: 150** → `warning` → Explicit handling → "Warning: Value too large"
3. **value: 7** → `debug` → Caught by `|?` → "Optional branch (ignored)"
4. **value: 2** → `trace` → Caught by `|?` → "Optional branch (ignored)"

All four calls complete successfully.

## Test Coverage

Part of comprehensive optional branches test suite:
- **Test 918**: Basic `|?` catch-all pattern
- **Test 918b** (this): Mix explicit handling + `|?` catch-all ← Real-world pattern!
- **Test 918d**: Shape validation (negative test)
- **Test 918e**: All-optional events (edge case)
- **Test 918f**: API evolution (required vs optional branches)
- **Test 918g**: `when` guards + `|?` interaction
- **Test 918h**: Event pump loop pattern (THE USE CASE)
- **Test 918i**: Error case without `|?` (runtime behavior)

## Files

- `input.kz` - Test case demonstrating mixed explicit + catch-all handling
- `expected.txt` - Expected output for all four code paths
- `MUST_RUN` - Requires execution
- `README.md` - This file
