# Bug Report: Inline Flow Chained Continuations

## Discovery
Found during fusion testing (test 1103). Created this core language test to isolate the issue from fusion-specific concerns.

## The Bug
Inline flow procs with chained continuations using the `|>` operator were completely broken due to **three separate bugs** in the compiler:

### Bug 1: Parser - Incorrect Continuation Nesting
**Location:** `src/parser.zig` `parseContinuationWithNested()` function

**Problem:** When parsing:
```koru
~proc calculate = add(x: a, y: b)
| done sum |> multiply(x: sum.result, factor: c)
| done product |> done { result: product.result }
```

The parser created TWO SIBLING continuations (both with branch="done") instead of NESTING the second under the first.

**Root Cause:** The parser only nested continuations with GREATER indentation. Continuations at the same indentation following a pipeline (`|>`) were incorrectly treated as siblings.

**Fix:** Added logic to detect when a continuation has a pipeline ending with an invocation, and peek ahead to check if the next same-indent continuation should actually be nested as a continuation of the pipeline's result.

**Files Modified:** `src/parser.zig:2794-2840`

### Bug 2: Bootstrap Emitter - No Support for Pipeline Invocations
**Location:** `koru_std/compiler_bootstrap.kz` inline flow emission

**Problem:** The inline flow emitter only handled branch constructors in pipelines:
```zig
// Worked:
| done d |> done { result: d.value }

// Failed (empty switch case):
| done sum |> multiply(...)
```

When `cont.pipeline[0]` was an invocation (not a branch_constructor), it generated an empty switch case `{}`!

**Root Cause:** The emitter only had a `.branch_constructor` case in the switch statement, with an `else => {}` fallback.

**Fix:** Added `.invocation` case that:
1. Captures parent binding if used in invocation args
2. Generates the invocation call
3. Recursively generates nested switch for nested continuations
4. Properly handles binding capture in nested levels

**Files Modified:** `koru_std/compiler_bootstrap.kz:1733-1821`

### Bug 3: Inline Flow Function Signature - Wrong Input Type
**Location:** `koru_std/compiler_bootstrap.kz` function signature generation

**Problem:** Inline flow functions used the FIRST INVOKED event's input type:
```zig
fn __inline_flow_1(args: add_event.Input) calculate_event.Output
//                       ^^^^^^^^^^^^^^^ WRONG - only has {x, y}
```

But chained continuations need access to ALL proc parameters:
```koru
| done sum |> multiply(x: sum.result, factor: c)
//                                            ^ 'c' is from proc params, not 'add' params!
```

**Root Cause:** Function signature generation looked up the invoked event's module/type instead of the proc's event type.

**Fix:** Changed signature generation to use the PROC's event input type, giving inline flows access to all proc parameters.

**Files Modified:** `koru_std/compiler_bootstrap.kz:1451-1499`

## Current Status

✅ **Fixed:** Parser nesting, emitter nested support, function signatures
❌ **Remaining:** Proc body call site still passes partial args

The proc body currently generates:
```zig
return __inline_flow_1(.{ .x = a }, .{ .y = b });
```

But needs to generate:
```zig
return __inline_flow_1(.{ .a = a, .b = b, .c = c });
```

This requires fixing the parser's inline flow extraction where it generates the proc body.

## Test Coverage Gap

**ZERO tests** in `000_CORE_LANGUAGE` for inline flow procs before this!

Only 6 tests total used inline flow syntax across the entire regression suite:
- 200_CONTROL_FLOW/210: Single chained continuation
- 200_CONTROL_FLOW/208: Expression flows
- 900_PHANTOM_TYPES/906: Numbering test
- 990_BUGS/997: Branch constructor bug
- 1100_FUSION/1103: Where we found the bug
- 9000_NEGATIVE_TESTS/9501: Negative test created during investigation

This is a **fundamental language feature** that was completely untested in core language tests!

## Related Tests

- **106_inline_flow_chained** (this test): Core test for chained continuations
- **1103_fusible_flows**: Fusion test that exposed the bug (same code pattern)
- **9501_inline_flow_continuation_chain**: Negative test for the bug

## Why This Matters

Inline flows with chained continuations are the **foundation** of Koru's compositional event model. This pattern:
```koru
~proc name = event1(..)
| branch x |> event2(arg: x.field)
| branch y |> done { result: y.data }
```

Is how you compose complex event chains without writing imperative handlers. The fact that this was completely broken shows we need **much better core language test coverage**!

## Expected Output

When working correctly, this test should:
1. Call `add(10, 20)` → returns `done { result: 30 }`
2. Bind as `sum`, call `multiply(30, 3)` → returns `done { result: 90 }`
3. Bind as `product`, return `done { result: 90 }`
4. Print: `Result: 90`

---

*This bug report documents one of the most significant test coverage gaps found in Koru's regression suite.*
