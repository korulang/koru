# Test 918d: Optional Branches - Shape Validation (NEGATIVE TEST)

## What This Test Verifies

This is a **negative test** that verifies shape checking still works for optional branches.

**Specific test case**: Handler tries to bind wrong payload shape on an optional branch. Should FAIL compilation.

## Critical Verification

This test proves that "optional" means:
- ✅ "Can be omitted by handler"
- ❌ NOT "can be misused with wrong payload"

Optional branches must still satisfy shape checking when they ARE handled.

## Test Structure

```koru
~event process { value: u32 }
| success { result: u32 }        // Payload: { result: u32 }
| ?warning { msg: []const u8 }   // Payload: { msg: []const u8 }

~process(value: 150)
| success { result } |> ...      // ✓ Correct: binds 'result' from success
| warning { result } |> ...      // ✗ ERROR: warning has 'msg', not 'result'!
```

## Expected Behavior

**Compilation should FAIL** with a shape mismatch error like:
```
error: continuation 'warning' expects payload { msg: []const u8 }
       but binding declares { result: ... }
```

The error should occur during **frontend compilation** (shape checking phase).

## Why This Matters

Without this test, we could have a bug where:
- Optional branches can be omitted ✓ (test 918)
- Optional branches can be used ✓ (test 918b)
- But shape checking is accidentally bypassed for optional branches ✗

This test closes that gap by proving shape checking is NOT disabled for optional branches.

## Comparison with Other Tests

- **Test 918**: Omits optional branch → compiles successfully ✓
- **Test 918b**: Uses optional branch correctly → compiles successfully ✓
- **Test 918d** (this): Uses optional branch INCORRECTLY → compilation ERROR ✓

## Test Coverage

Part of comprehensive optional branches test suite:
- **Test 918**: Handlers OMIT optional branches
- **Test 918b**: Handlers HANDLE optional branches correctly
- **Test 918c**: Mixed usage (some handled, some not)
- **Test 918d** (this): Shape validation error ← Safety check!
- **Test 918e**: All-optional events (edge case)

## Files

- `input.kz` - Test case with intentional shape mismatch on optional branch
- `EXPECT` - Contains FRONTEND_COMPILE_ERROR marker
- `README.md` - This file

## Test Execution

This test succeeds if compilation FAILS. The regression runner looks for FRONTEND_COMPILE_ERROR in the EXPECT file.
