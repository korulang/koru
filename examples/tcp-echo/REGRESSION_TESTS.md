# Regression Tests for TCP Echo Server Bugs

## Summary

The TCP echo server found 3 bugs in the Koru compiler. Each bug now has a regression test to prevent regressions.

## Bug #1: Zig Keyword Escaping in Union Branches

**Test**: `tests/regression/203d_zig_keyword_escaping/`
**Status**: ❌ FAILING (expected - captures the bug)

**What it tests**: Branch names that are Zig keywords (like `error`) should be escaped with `@"..."` syntax in generated code.

**Example**:
```koru
~event check { value: i32 }
| error { msg: []const u8 }  // "error" is a Zig keyword
| ok { result: i32 }
```

**Expected behavior**: Generated code should have `@"error": struct { ... }`
**Actual behavior**: Generated code has `error: struct { ... }` causing Zig parse error

**Error message**:
```
output_emitted.zig:76:18: error: expected '.', found ':'
```

## Bug #2: Namespace Handling in Nested Flows

**Test**: `tests/regression/827_namespace_nested_flow/`
**Status**: ❌ FAILING (expected - captures the bug)

**What it tests**: When events use namespaces (e.g., `net.connect`), nested flow invocations should consistently include or omit the namespace prefix.

**Example**:
```koru
~event net.connect { host: []const u8 }
| connected { id: u32 }

~event net.send { id: u32, data: []const u8 }
| sent { bytes: usize }

// Nested invocation - triggers inconsistent codegen
~net.connect(host: "localhost")
| connected c |> net.send(id: c.id, data: "hello")
    | sent s |> _
```

**Expected behavior**: Generated code should consistently use `net.connect.handler(...)` and `net.send.handler(...)`
**Actual behavior**: Some calls have namespace prefix, others don't, causing undeclared identifier errors

**Error message**:
```
output_emitted.zig:142:41: error: use of undeclared identifier 'net'
```

## Bug #3: Nested Label Loops

**Test**: `tests/regression/828_nested_labels/`
**Status**: ❌ FAILING (expected - captures the bug)

**What it tests**: When labels are nested (one label scope inside another), the compiler should generate all required label functions.

**Example**:
```koru
// Outer label with inner label nested inside
~#outer outer(count: 0)
| continue_outer o |> #inner inner(count: 0)
    | continue_inner i |> @inner inner(count: i.next)  // Inner loop
    | done_inner |> @outer outer(count: o.next)        // Outer loop
| done_outer |> _
```

**Expected behavior**: Generated code should define both `flow0_outer` and `flow0_inner` functions
**Actual behavior**: Compiler generates tail calls to these functions but never defines them

**Error message**:
```
output_emitted.zig:146:52: error: use of undeclared identifier 'flow0_inner'
```

**Note**: Simple single-label loops work fine (see `tests/regression/203_labels_and_jumps/` which passes). The bug only appears with nested labels.

## Comparison with Existing Tests

### What Works (Passing Tests)
- **203_labels_and_jumps**: Simple single-label loops ✅
- Single-namespace events without nesting ✅
- Branch names that aren't Zig keywords ✅

### What Breaks (New Failing Tests)
- **203d_zig_keyword_escaping**: Keyword branch names ❌
- **827_namespace_nested_flow**: Namespaced events in nested flows ❌
- **828_nested_labels**: Nested label scopes ❌

## Running the Tests

```bash
# Run individual tests
./run_regression.sh 203d  # BUG #1
./run_regression.sh 827   # BUG #2
./run_regression.sh 828   # BUG #3

# Run all regression tests
./run_regression.sh
```

## Test Results

As of this commit:
- **Total tests**: 72
- **Passing**: 57 (79%)
- **Failing**: 15
  - 3 are our new tests (expected failures)
  - 12 are pre-existing failures

## When These Tests Should Pass

These tests are deliberately failing to capture known bugs. They should start passing when:

1. **203d**: Compiler escapes Zig keywords in generated union branch names
2. **827**: Compiler fixes namespace prefixing consistency in nested flows
3. **828**: Compiler generates all label functions for nested label scopes

The tests will automatically turn green once the underlying bugs are fixed.
