# Negative Tests - Compiler Error Validation

This directory contains tests that validate the compiler's error messages and failure modes. These tests ensure that:
1. Invalid code is properly rejected
2. Error messages are clear and actionable
3. The compiler fails gracefully without crashes
4. Error detection happens at the correct compilation phase

## Directory Structure

```
9000_NEGATIVE_TESTS/
├── 9100_PARSE_ERRORS/       # Syntax errors caught by parser
├── 9200_TYPE_ERRORS/        # Type system violations
├── 9300_PURITY_VIOLATIONS/  # Purity analysis errors
├── 9400_FUSION_ERRORS/      # Fusion optimization errors
└── 9500_COMPILER_CRASHES/   # Graceful handling of edge cases
```

## Test Configuration

Each negative test directory must contain:

### Required Files

1. **input.kz** - The invalid Koru code that should be rejected

2. **EXPECT** - Specifies what kind of error to expect:
   ```
   FRONTEND_COMPILE_ERROR
   ```
   or
   ```
   BACKEND_COMPILE_ERROR
   ```
   or
   ```
   BACKEND_RUNTIME_ERROR
   ```

3. **expected_error.txt** - Pattern to match in error output:
   ```
   error: undefined event 'foo'
   ```
   The test passes if this substring appears in the compiler's error output.

### Optional Files

- **DESCRIPTION** - Human-readable explanation of what this test validates
- **COMPILER_FLAGS** - Additional compiler flags to pass (one per line)

## Error Phase Definitions

### FRONTEND_COMPILE_ERROR
Errors during `.kz` → `backend.zig` compilation:
- Syntax errors (malformed Koru code)
- Parse errors (invalid tokens, structure)
- Module resolution failures
- Import errors

### BACKEND_COMPILE_ERROR
Errors during `backend.zig` → executable compilation or during backend execution that produce Zig compilation errors:
- Type mismatches after deserialization
- Invalid generated Zig code
- Struct/union generation errors
- Code generation failures

### BACKEND_RUNTIME_ERROR
Errors during backend execution (validation/analysis errors):
- Purity violations detected by purity analyzer
- Shape checking failures
- Phantom type violations
- Fusion detection/transformation errors
- Any semantic validation that happens at "comptime"

## Writing Negative Tests

### Example 1: Parse Error (9100)

**9100_PARSE_ERRORS/9101_missing_pipe/input.kz:**
```koru
~event foo { x: i32 } | done { result: i32 }
~proc foo = done { result: x }  // Missing | before branch
```

**EXPECT:**
```
FRONTEND_COMPILE_ERROR
```

**expected_error.txt:**
```
error: expected '|' before branch constructor
```

### Example 2: Type Error (9200)

**9200_TYPE_ERRORS/9201_wrong_branch_type/input.kz:**
```koru
~event add { x: i32, y: i32 } | done { result: i32 }
~proc add = done { result: "not a number" }  // String instead of i32
```

**EXPECT:**
```
BACKEND_RUNTIME_ERROR
```

**expected_error.txt:**
```
error: type mismatch in branch 'done'
```

### Example 3: Purity Violation (9300)

**9300_PURITY_VIOLATIONS/9301_impure_in_pure_flow/input.kz:**
```koru
~event impure_thing { x: i32 } | done {}
~proc impure_thing {
    std.debug.print("side effect!\n", .{});
    return .{ .done = .{} };
}

~event pure_thing { x: i32 } | done {}
~proc pure_thing = impure_thing(x: x) | done {}  // Pure flow calling impure event!
```

**EXPECT:**
```
BACKEND_RUNTIME_ERROR
```

**expected_error.txt:**
```
error: pure flow cannot call impure event 'impure_thing'
```

### Example 4: Compiler Crash Prevention (9500)

**9500_COMPILER_CRASHES/9501_null_pointer_handling/input.kz:**
```koru
// Intentionally malformed AST that might cause null pointer access
~event @invalid_path.deeply.nested { x: i32 } | done {}
```

**EXPECT:**
```
FRONTEND_COMPILE_ERROR
```

**expected_error.txt:**
```
error:
```
(Just verify it produces SOME error, not crash with no output)

## Test Execution

Negative tests run exactly like positive tests, but:
1. The test **passes** if compilation fails as expected
2. The test **fails** if compilation succeeds
3. Error message matching is substring-based (grep -qF)
4. Memory leaks still fail the test (unless --check-leaks is off)

## Philosophy

**Negative tests are just as important as positive tests.**

They ensure:
- Users get helpful error messages, not crashes
- Invalid code is caught early in the pipeline
- Error messages guide users toward fixes
- Regression prevention: once we fix a confusing error message, we never regress

**"Failing tests are beautiful"** - but only when they fail *correctly*.

## Integration with Regression Suite

The main regression script (`run_regression.sh`) already supports:
- `EXPECT` file for specifying expected failure phase
- `expected_error.txt` for matching error patterns
- Memory leak detection even in failing tests
- Proper error phase attribution (frontend vs backend)

Negative tests use the same infrastructure as positive tests - they just expect failure instead of success.

## Adding New Negative Tests

1. Choose the appropriate category (9100-9500)
2. Create a numbered directory: `9XXX_descriptive_name/`
3. Write the invalid `input.kz`
4. Create `EXPECT` file with failure phase
5. Create `expected_error.txt` with error pattern
6. Optionally add `DESCRIPTION` for documentation
7. Run with: `./run_regression.sh 9XXX`
8. Verify the test passes (shows green checkmark for expected error)

## Benefits

- **Documentation**: Negative tests document what SHOULDN'T work
- **Error Quality**: Forces us to write clear error messages
- **Regression Prevention**: Catches error message regressions
- **Edge Case Coverage**: Tests boundary conditions and malformed input
- **User Experience**: Better errors = happier developers

---

Remember: **A test that expects an error and gets one is a SUCCESS** ✅
