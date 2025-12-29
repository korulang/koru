# Test 918g: Optional Branches - `when` Guards + `|?` Interaction

## What This Test Verifies

This test demonstrates the **elegant interaction** between `when` guards and `|?` catch-all:

- Handler uses `when` guards for **partial matching** on a branch
- `|?` catch-all handles **unguarded cases** from optional branches
- Shows fine-grained control without exhaustive handling

## The Pattern

```koru
~event pump {}
| ?mouse_event { code: i32 }
| ?keyboard_event { code: i32 }

~pump()
| mouse_event { code } when (code == LEFT_CLICK) |> handle_left_click()
| mouse_event { code } when (code == RIGHT_CLICK) |> handle_right_click()
| keyboard_event { code } when (code == ENTER) |> handle_enter()
|? |> continue  // Catches: other mouse codes, other keyboard codes
```

**What `|?` catches here:**
- `mouse_event` with codes other than LEFT_CLICK or RIGHT_CLICK
- `keyboard_event` with codes other than ENTER
- Any other optional branches

This is **elegant** because:
- You get fine-grained control (specific codes handled specially)
- You don't need exhaustive `when` guards
- You don't need fallthrough for each branch
- `|?` provides a single catch-all for everything else

## Semantics Question

**Does `|?` catch partial matches or only unhandled branches?**

**Option A**: `|?` catches any optional branch execution path not taken
- `mouse_event` with code 1 → matches `mouse_event` but not `when` guards → caught by `|?`

**Option B**: `|?` only catches branches with NO handler at all
- `mouse_event` with code 1 → matches `mouse_event` handlers, must be exhaustive or have fallthrough

**This test assumes Option A** (catch unguarded cases). This is more useful and elegant.

## Test Structure

```koru
~event process { value: u32 }
| success { result: u32 }                    // REQUIRED
| ?warning { msg: []const u8, level: u32 }   // OPTIONAL with guards

~process(value: X)
| success { result } |> handle_success(result)
| warning { level } when (level > 5) |> handle_critical()
| warning { level } when (level > 2) |> handle_moderate()
|? |> continue  // Catches: warning with level <= 2, any other optional branches
```

## Test Behavior

Multiple calls test different guard paths:

1. **Success path** → Explicit handler
2. **Warning level 10** → First `when` guard matches (level > 5)
3. **Warning level 4** → Second `when` guard matches (level > 2)
4. **Warning level 1** → No guards match → Caught by `|?`

## Why This Matters

Without `|?` + `when` interaction, you'd need:

**Without `|?`** (exhaustive guards):
```koru
| warning { level } when (level > 5) |> critical()
| warning { level } when (level > 2) |> moderate()
| warning { level } |> default()  // Explicit fallthrough
```

**With `|?`** (catch-all):
```koru
| warning { level } when (level > 5) |> critical()
| warning { level } when (level > 2) |> moderate()
|? |> continue  // Also handles other optional branches!
```

The `|?` version is cleaner and handles multiple optional branches at once.

## Test Coverage

Part of comprehensive optional branches test suite:
- **Test 918**: Basic `|?` catch-all pattern
- **Test 918b**: Mix explicit handling + `|?` catch-all
- **Test 918d**: Shape validation (negative test)
- **Test 918e**: All optional + only `|?` (edge case)
- **Test 918f**: API evolution (anti-F# discard)
- **Test 918g** (this): `when` guards + `|?` interaction ← Elegant pattern!
- **Test 918h**: Event pump loop pattern (THE USE CASE)
- **Test 918i**: Error case without `|?` (runtime behavior)

## Files

- `input.kz` - Demonstrates `when` guards with `|?` fallthrough
- `expected.txt` - Different paths for different guard matches
- `MUST_RUN` - Requires execution
- `README.md` - This file
