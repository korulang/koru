# Koru LLM Tutorial (Ground Truth from SUCCESS Tests)

Generated **only** from `tests/regression/**/SUCCESS` cases. Ignores `.md` files.
Preference baked in: **subflow implementations** and **std.io events** over Zig `std` escape hatches.

## Preference Rules
- Prefer `~event = ...` or `~proc name = ...` (subflow/inline flow) over block procs.
- Prefer `~import "$std/io"` + `std.io:*` events for output instead of Zig `std` calls.

## Preferred: Subflow Implementations

### Example from `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_055_inline_pipe_in_string/input.kz`
```koru

~event greet { text: []const u8 }
| greeted {}

~greet = greeted {}

// The "|>" here is part of the string, not an inline continuation.
~greet(text: "Hello |> World")
| greeted |> _
```

### Example from `tests/regression/100_PARSER/100_052_braceless_branch_constructors/input.kz`
```koru

~import "$std/io"

// Event with identity branch
~pub event empty_result {}
| ok
| fail

// Event with value branch
~pub event value_result {}
| success i32
| fail

// Subflow impl using braceless syntax for empty identity branch
// OLD syntax: ~empty_result = ok {}
// NEW syntax:
~empty_result = ok

// Subflow impl using braceless syntax with value
// OLD syntax: ~value_result = success { 42 }
// NEW syntax:
~value_result = success 42

// Main entry point
~std.io:print.ln("Testing empty braceless:")
~empty_result()
| ok |> std.io:print.ln("  Got ok!")
| fail |> std.io:print.ln("  Got fail!")

~std.io:print.ln("Testing value braceless:")
~value_result()
| success n |> std.io:print.ln("  Got success: {{ n:d }}")
| fail |> std.io:print.ln("  Got fail!")
```

### Example from `tests/regression/300_ADVANCED_FEATURES/330_PHANTOM_TYPES/330_019_auto_discharge_branch_constructor/input.kz`
```koru

~import "$app/fs"

// Event that wraps file opening and returns a status
~event check_file { path: []const u8 }
| result { status: []const u8 }

// Subflow: opens file, returns status - SHOULD auto-discharge the file!
// Using _ for binding since auto-discharge should synthesize _auto_N
~check_file = app.fs:open(path: path)
| opened _ |> result { status: "file exists" }  // obligation should be auto-discharged before returning!

// Main flow
~check_file(path: "test.txt")
| result _ |> _
```

### Example from `tests/regression/300_ADVANCED_FEATURES/395_TESTING/395_009_cross_module_mock/input.kz`
```koru

~import "$std/testing"
~import "$std/fs"

// A flow that depends on an external module event
~event process_config { path: []const u8 }
| ok { line_count: usize }
| failed { reason: []const u8 }

~process_config = std.fs:read_lines(path: path)
| lines l |> ok { line_count: l.len }
| failed msg |> failed { reason: msg }

// ============================================
// THE TEST - Cross-module mock
// ============================================

~test(Cross-module mock with failed branch) {
    // Mock the external module's event with the 'failed' branch
    // This returns a simple string ([]const u8), which works without array literals
    ~std.fs:read_lines = failed "mocked file read error"

    ~process_config(path: "/this/file/does/not/exist.txt")
    | ok |> assert.fail()
    | failed result |> assert(result.reason.len > 0)
}

// ============================================
// FUTURE: Array literal test (feature gap)
// ============================================
//
// Once Koru has array literal syntax, add this test:
//
// ~test(Cross-module mock should return 3 lines) {
//     ~std.fs:read_lines = lines ["line1", "line2", "line3"]
//
//     ~process_config(path: "/fake/path")
//     | ok result |> assert(result.line_count == 3)
//     | failed |> assert.fail()
// }
//
// FEATURE GAP: Koru needs native array literals like ["a", "b"]
// WORKAROUND: Use &.{ "a", "b" } Zig escape when available
```

### Example from `tests/regression/300_ADVANCED_FEATURES/395_TESTING/395_004_constant_event_auto_inline/input.kz`
```koru

~import "$std/testing"

// Event with constant implementation (immediate branch constructor)
~event get_config {}
| config { timeout: u32, retries: u32 }

// Constant implementation - always returns the same value
~get_config = config { timeout: 30, retries: 3 }

// Test: NO MOCK NEEDED - constant is auto-detected and inlined!
// Verify the constant values are correct
~test(Constant event auto-inlined) {
    ~get_config()
    | config c |> assert(c.timeout == 30)
}
```

### Example from `tests/regression/300_ADVANCED_FEATURES/350_SUBFLOWS/301_subflow_immediate/input.kz`
```koru

~import "$std/io"

// Event: takes a name, produces a greeting message
~event greet { name: []const u8 }
| greeting { message: []const u8 }

// Subflow implementation: maps input field 'name' to output field 'message'
~greet = greeting { message: name }

// Test: call greet with "World" and print the resulting message
~greet(name: "World")
| greeting g |> std.io:print(text: g.message)
```

## Preferred: Std IO over Zig std

### Example from `tests/regression/900_EXAMPLES_SHOWCASE/900_HELLO_WORLD/input.kz`
```koru

~import "$std/io"

const name = "World";
const debug = true;
const count: i32 = 42;

~std.io:print.blk {
    {% if debug %}[DEBUG] {% endif %}Hello, {{ name:s }}!
    The answer is {{ count:d }}.
}
```

### Example from `tests/regression/200_COMPILER_FEATURES/220_COMPILATION/220_005_cross_module_type_nullable/input.kz`
```koru
~import "$std/interpreter"
~import "$std/io"

~pub event test_nullable {
    pool: ?*std.interpreter:HandlePool,
}
| done {}

~proc test_nullable {
    return .{ .done = .{} };
}

~test_nullable(pool: null)
| done |> std.io:println(text: "done")
```

### Example from `tests/regression/200_COMPILER_FEATURES/240_STD_LIBRARY/240_020_args_basic/input.kz`
```koru
~import "$std/args"
~import "$std/io"

// Get argument count
~std.args:count()
| count n |>
    std.io:print.ln("arg count: {{ n:d }}")

// Get program name (index 0) - just verify we can access it
~std.args:get(index: 0)
| arg _ |> std.io:print.ln("has program name: yes")
| out_of_bounds |> std.io:print.ln("no args?!")

// Get rest (skipping program name)
~std.args:rest()
| args r |>
    std.io:print.ln("rest count: {{ r.len:d }}")
```

### Example from `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_042_orisha_pattern/input.kz`
```koru

~import "$std/io"
~import "$std/control"

~std.control:if(cond: true)
  | then |>
    std.io:println(text: "then branch")
  | else |>
    std.io:println(text: "else branch")
```

### Example from `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_045_source_block_in_pipeline/input.kz`
```koru

~import "$std/io"

// First: void event to start a pipeline
~event setup {}
| ready {}

~proc setup {
    return .{ .ready = .{} };
}

// Now use print.blk INSIDE the pipeline continuation
~setup()
| ready |> std.io:print.blk {
    Hello from inside a pipeline!
  }
```

### Example from `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_044_source_block_with_branches/input.kz`
```koru

~import "$std/io"

// Use print.blk which we KNOW works, as baseline
~std.io:print.blk {
    Hello, World!
}

// If we can get here without parse errors, the basic syntax works.
// The sqlite3:query case that needs args is tested separately in koru-libs.
```

## Top-Level Forms

### Example from `tests/regression/900_EXAMPLES_SHOWCASE/900_HELLO_WORLD/input.kz`
```koru

~import "$std/io"

const name = "World";
const debug = true;
const count: i32 = 42;

~std.io:print.blk {
    {% if debug %}[DEBUG] {% endif %}Hello, {{ name:s }}!
    The answer is {{ count:d }}.
}
```

### Example from `tests/regression/200_COMPILER_FEATURES/220_COMPILATION/902_compiler_flags_declare/input.kz`
```koru

~std.compiler:flag.declare {
  "name": "test",
  "description": "Test flag",
  "type": "boolean"
}

~event hello {}
| done {}

~hello()
| done |> _
```

### Example from `tests/regression/200_COMPILER_FEATURES/220_COMPILATION/901_compiler_requires/input.kz`
```koru

~std.compiler:requires {
    exe.linkSystemLibrary("sqlite3");
}

~std.compiler:requires {
    exe.linkSystemLibrary("c");
}

~event hello {}
| done {}

~hello()
| done |> _
```

### Example from `tests/regression/200_COMPILER_FEATURES/220_COMPILATION/220_001_cross_module_type_basic/input.kz`
```koru

~event process_user {
    user_data: test_lib.user:User,
    value: i32,
}
| done { success: bool }
```

### Example from `tests/regression/200_COMPILER_FEATURES/220_FLOW_CHECKER/220_002_discard_binding_ok/input.kz`
```koru

~import "$app/fs"

// OK: _ is explicit discard - no KORU100 error
~app.fs:open(path: "test.txt")
| opened _ |> _
```

### Example from `tests/regression/200_COMPILER_FEATURES/220_FLOW_CHECKER/220_001_unused_binding_error/input.kz`
```koru

~import "$app/fs"

// ERROR: f is bound but never used - should trigger KORU100
~app.fs:open(path: "test.txt")
| opened f |> _
```

## Flows and Continuations

### Example from `tests/regression/900_EXAMPLES_SHOWCASE/900_HELLO_WORLD/input.kz`
```koru

~import "$std/io"

const name = "World";
const debug = true;
const count: i32 = 42;

~std.io:print.blk {
    {% if debug %}[DEBUG] {% endif %}Hello, {{ name:s }}!
    The answer is {{ count:d }}.
}
```

### Example from `tests/regression/200_COMPILER_FEATURES/220_COMPILATION/902_compiler_flags_declare/input.kz`
```koru

~std.compiler:flag.declare {
  "name": "test",
  "description": "Test flag",
  "type": "boolean"
}

~event hello {}
| done {}

~hello()
| done |> _
```

### Example from `tests/regression/200_COMPILER_FEATURES/220_COMPILATION/901_compiler_requires/input.kz`
```koru

~std.compiler:requires {
    exe.linkSystemLibrary("sqlite3");
}

~std.compiler:requires {
    exe.linkSystemLibrary("c");
}

~event hello {}
| done {}

~hello()
| done |> _
```

### Example from `tests/regression/200_COMPILER_FEATURES/220_COMPILATION/220_001_cross_module_type_basic/input.kz`
```koru

~event process_user {
    user_data: test_lib.user:User,
    value: i32,
}
| done { success: bool }
```

### Example from `tests/regression/200_COMPILER_FEATURES/220_FLOW_CHECKER/220_002_discard_binding_ok/input.kz`
```koru

~import "$app/fs"

// OK: _ is explicit discard - no KORU100 error
~app.fs:open(path: "test.txt")
| opened _ |> _
```

### Example from `tests/regression/200_COMPILER_FEATURES/220_FLOW_CHECKER/220_001_unused_binding_error/input.kz`
```koru

~import "$app/fs"

// ERROR: f is bound but never used - should trigger KORU100
~app.fs:open(path: "test.txt")
| opened f |> _
```

## Bindings and Discards

### Example from `tests/regression/200_COMPILER_FEATURES/220_FLOW_CHECKER/220_002_discard_binding_ok/input.kz`
```koru

~import "$app/fs"

// OK: _ is explicit discard - no KORU100 error
~app.fs:open(path: "test.txt")
| opened _ |> _
```

### Example from `tests/regression/200_COMPILER_FEATURES/220_FLOW_CHECKER/220_001_unused_binding_error/input.kz`
```koru

~import "$app/fs"

// ERROR: f is bound but never used - should trigger KORU100
~app.fs:open(path: "test.txt")
| opened f |> _
```

### Example from `tests/regression/200_COMPILER_FEATURES/240_STD_LIBRARY/240_020_args_basic/input.kz`
```koru
~import "$std/args"
~import "$std/io"

// Get argument count
~std.args:count()
| count n |>
    std.io:print.ln("arg count: {{ n:d }}")

// Get program name (index 0) - just verify we can access it
~std.args:get(index: 0)
| arg _ |> std.io:print.ln("has program name: yes")
| out_of_bounds |> std.io:print.ln("no args?!")

// Get rest (skipping program name)
~std.args:rest()
| args r |>
    std.io:print.ln("rest count: {{ r.len:d }}")
```

### Example from `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_006_flow_checker_validation/input.kz`
```koru

~event check { x: i32, y: i32 }
| high { x: i32 }
| low { y: i32 }

// Valid: Two when-clauses + one else case
~check(x: 10, y: 5)
| high h when (h.x > 10) |> _
| high h when (h.x > 5) |> _
| high |> _  // else case
| low |> _
```

### Example from `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_007_flow_checker_missing_else/input.kz`
```koru

~event check { x: i32, y: i32 }
| high { x: i32 }
| low { y: i32 }

// Invalid: Two when-clauses but NO else case (non-exhaustive)
~check(x: 10, y: 5)
| high h when (h.x > 10) |> _
| high h when (h.x > 5) |> _
// Missing: | high h |> _ (else case)
| low |> _
```

### Example from `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_004_branch_when_clauses/input.kz`
```koru

~event check { x: i32, y: i32 }
| high { x: i32 }
| low { y: i32 }

// Flow with multiple continuations for same branch using when clauses
~check(x: 10, y: 5)
| high h when (h.x > 10) |> _
| high h when (h.x > 5) |> _
| high _ |> _
| low _ |> _
```

## When Guards

### Example from `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_006_flow_checker_validation/input.kz`
```koru

~event check { x: i32, y: i32 }
| high { x: i32 }
| low { y: i32 }

// Valid: Two when-clauses + one else case
~check(x: 10, y: 5)
| high h when (h.x > 10) |> _
| high h when (h.x > 5) |> _
| high |> _  // else case
| low |> _
```

### Example from `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_007_flow_checker_missing_else/input.kz`
```koru

~event check { x: i32, y: i32 }
| high { x: i32 }
| low { y: i32 }

// Invalid: Two when-clauses but NO else case (non-exhaustive)
~check(x: 10, y: 5)
| high h when (h.x > 10) |> _
| high h when (h.x > 5) |> _
// Missing: | high h |> _ (else case)
| low |> _
```

### Example from `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_022_invocation_parentheses_rules/input.kz`
```koru

// VALID: Zero params, no source block → requires ()
~event voidCall {}
~voidCall()

// VALID: Zero params, source block → NO ()
~event renderSimple { source: Source[HTML] }
~renderSimple {
    <h1>Hello!</h1>
}

// VALID: With params, source block → requires () for params
~event renderWithData { name: []const u8, source: Source[HTML] }
~renderWithData(name: "Alice") {
    <p>${name}</p>
}

// VALID: Chained void calls
~event stepOne {}
~event stepTwo {}
~stepOne() |> stepTwo()

// INVALID CASES (should be parser errors):
// ~voidCall                          // Missing () when no source block
```

### Example from `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_004_branch_when_clauses/input.kz`
```koru

~event check { x: i32, y: i32 }
| high { x: i32 }
| low { y: i32 }

// Flow with multiple continuations for same branch using when clauses
~check(x: 10, y: 5)
| high h when (h.x > 10) |> _
| high h when (h.x > 5) |> _
| high _ |> _
| low _ |> _
```

### Example from `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_003_conditional_imports/input.kz`
```koru

// Unconditional import (baseline) - should appear in AST
~import "$std/compiler"

// Conditional imports - should NOT appear in AST (deadstripped)
~[profile]import "$std/profiler"

~[test]import "$std/testing"

~[debug|trace]import "$std/debug"

~event hello {}
| done {}
```

### Example from `tests/regression/100_PARSER/100_080_nested_when_guards/input.kz`
```koru

~event run {}
| ready { t: i32 }
| err {}

~event poll { t: i32 }
| key { code: u8 }
| done {}

~event cleanup {}
| done {}

~event handle_key { code: u8 }
| done {}

~run()
| ready t |> poll(t: t.t)
    | key k when (k.code == 'q') |> cleanup()
        | done |> _
    | key k |> handle_key(code: k.code)
        | done |> _
    | done |> _
| err _ |> _
```

## Labels and Jumps

### Example from `tests/regression/300_ADVANCED_FEATURES/320_STDLIB/320_033_println_koru_scope/input.kz`
```koru

~import "$std/io"
~import "$std/control"

// Use ~capture to create a Koru binding, then print it
~capture(expr: { total: @as(i32, 0) })
| as |> captured { total: 42 }
| captured final |> std.io:print.ln("Captured total: {{ final.total:d }}")
```

### Example from `tests/regression/300_ADVANCED_FEATURES/320_STDLIB/320_042_capture_if_for_multi/input.kz`
```koru

~import "$std/io"
~import "$std/control"

~capture({ sum: @as(i64, 0), count: @as(i32, 0) })
| as acc |> for(&[_]i32{1, 3, 6, 8, 10})
    | each item |> if(item > 5)
        | then |> captured { sum: acc.sum + @as(i64, item), count: acc.count + 1 }
        | else |> captured { sum: acc.sum, count: acc.count }
| captured result |> std.io:print.ln("{{ @divTrunc(result.sum, @as(i64, result.count)):d }}")
```

### Example from `tests/regression/300_ADVANCED_FEATURES/320_STDLIB/320_081_ecology_pass_ran_mechanism/input.kz`
```koru

~import "$std/control"
~import "$std/io"

// Use nested control flow - each should only transform ONCE
~for(0..2)
| each i |>
    if(i > 0)
    | then |> std.io:println(text: "nested transform")
    | else |> std.io:println(text: "first iteration")
| done |> std.io:println(text: "done")
```

### Example from `tests/regression/300_ADVANCED_FEATURES/320_STDLIB/320_043_const_basic/input.kz`
```koru

~import "$std/io"
~import "$std/control"

~const({ threshold: @as(i32, 5), multiplier: @as(i32, 2) })
| as cfg |> capture({ sum: @as(i64, 0), count: @as(i32, 0) })
    | as acc |> for(&[_]i32{1, 3, 6, 8, 10})
        | each item |> if(item > cfg.threshold)
            | then |> captured { sum: acc.sum + @as(i64, item) * cfg.multiplier, count: acc.count + 1 }
            | else |> captured { sum: acc.sum, count: acc.count }
    | captured result |> std.io:print.ln("{{ result.sum:d }}")
```

### Example from `tests/regression/300_ADVANCED_FEATURES/320_STDLIB/320_044_const_simple/input.kz`
```koru

~import "$std/io"
~import "$std/control"

~const({ x: @as(i32, 10), y: @as(i32, 20) })
| as cfg |> std.io:print.ln("{{ cfg.x + cfg.y:d }}")
```

### Example from `tests/regression/500_INTEGRATION_TESTING/510_NEGATIVE_TESTS/510_090_unknown_label_error/input.kz`
```koru

~event foo {}
| done {}

~foo()
| done |> @missing()
```

## Imports and Namespaces

### Example from `tests/regression/900_EXAMPLES_SHOWCASE/900_HELLO_WORLD/input.kz`
```koru

~import "$std/io"

const name = "World";
const debug = true;
const count: i32 = 42;

~std.io:print.blk {
    {% if debug %}[DEBUG] {% endif %}Hello, {{ name:s }}!
    The answer is {{ count:d }}.
}
```

### Example from `tests/regression/200_COMPILER_FEATURES/220_FLOW_CHECKER/220_002_discard_binding_ok/input.kz`
```koru

~import "$app/fs"

// OK: _ is explicit discard - no KORU100 error
~app.fs:open(path: "test.txt")
| opened _ |> _
```

### Example from `tests/regression/200_COMPILER_FEATURES/220_FLOW_CHECKER/220_001_unused_binding_error/input.kz`
```koru

~import "$app/fs"

// ERROR: f is bound but never used - should trigger KORU100
~app.fs:open(path: "test.txt")
| opened f |> _
```

### Example from `tests/regression/200_COMPILER_FEATURES/240_STD_LIBRARY/240_020_args_basic/input.kz`
```koru
~import "$std/args"
~import "$std/io"

// Get argument count
~std.args:count()
| count n |>
    std.io:print.ln("arg count: {{ n:d }}")

// Get program name (index 0) - just verify we can access it
~std.args:get(index: 0)
| arg _ |> std.io:print.ln("has program name: yes")
| out_of_bounds |> std.io:print.ln("no args?!")

// Get rest (skipping program name)
~std.args:rest()
| args r |>
    std.io:print.ln("rest count: {{ r.len:d }}")
```

### Example from `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_042_orisha_pattern/input.kz`
```koru

~import "$std/io"
~import "$std/control"

~std.control:if(cond: true)
  | then |>
    std.io:println(text: "then branch")
  | else |>
    std.io:println(text: "else branch")
```

### Example from `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_044_source_block_with_branches/input.kz`
```koru

~import "$std/io"

// Use print.blk which we KNOW works, as baseline
~std.io:print.blk {
    Hello, World!
}

// If we can get here without parse errors, the basic syntax works.
// The sqlite3:query case that needs args is tested separately in koru-libs.
```

## Phantom Types and Obligations

### Example from `tests/regression/300_ADVANCED_FEATURES/330_PHANTOM_TYPES/330_006_cleanup_consumed_by_disposal/input.kz`
```koru

~import "$app/fs"

~app.fs:open(path: "test.txt")
| opened f |> app.fs:close(file: f.file)
    | closed |> _
```

### Example from `tests/regression/300_ADVANCED_FEATURES/330_PHANTOM_TYPES/330_007_use_after_disposal/input.kz`
```koru

~import "$app/fs"

~app.fs:open(path: "test.txt")
| opened f |> app.fs:close(file: f.file)
    | closed |> app.fs:use_file(file: f.file)  // ERROR: f.file was disposed!
        | used |> _
```

### Example from `tests/regression/300_ADVANCED_FEATURES/330_PHANTOM_TYPES/330_011_auto_discharge_multiple/input.kz`
```koru

~import "$app/fs"

// This should FAIL - two disposal options, be explicit!
~app.fs:open(path: "test.txt")
| opened _ |> _
```

### Example from `tests/regression/300_ADVANCED_FEATURES/330_PHANTOM_TYPES/330_041_auto_discharge_single/input.kz`
```koru

~import "$app/fs"

// Flow terminates without explicit close - should auto-insert close()
// Using _ to discard - auto-discharge will synthesize a binding
~app.fs:open(path: "test.txt")
| opened _ |> _
```

### Example from `tests/regression/300_ADVANCED_FEATURES/330_PHANTOM_TYPES/330_012_auto_discharge_none/input.kz`
```koru

~import "$app/fs"

// This should FAIL - no way to dispose!
~app.fs:open(path: "test.txt")
| opened _ |> _
```

### Example from `tests/regression/300_ADVANCED_FEATURES/330_PHANTOM_TYPES/520_multiple_resources_cleanup/input.kz`
```koru

~import "$app/fs"

~app.fs:open_two(path1: "test1.txt", path2: "test2.txt")
| opened f |> app.fs:close(file: f.file1)  // Close first file
    | closed |> app.fs:close(file: f.file2)  // Close second file
        | closed |> _  // Both cleaned up!
```

## Comptime and Metaprogramming

### Example from `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_010_module_annotations/input.kz`
```koru
~[comptime]

// Test that module annotations are captured in the AST
~pub event test.event { value: u32 }
| result { output: u32 }
```

### Example from `tests/regression/700_EVENT_GLOBBING/700_001_glob_declaration_syntax/input.kz`
```koru

// This is a glob pattern event - a template for any log.* event
// Marked [norun] since we're just testing syntax acceptance, not transform execution
~[comptime|transform|norun]pub event log.* {
    message: []const u8,
}
| ok { }

// A concrete event that matches the glob pattern
~pub event log.info {
    message: []const u8,
}
| ok { }

~proc log.info {
    return .{ .ok = .{} };
}

// Test invocation of the concrete event
~log.info(message: "Hello from glob event")
| ok |> _
```

### Example from `tests/regression/200_COMPILER_FEATURES/220_COMPILATION/220_010_module_annotation_serialization/input.kz`
```koru

~import "$std/io"

~event hello {}
| done {}

~proc hello {
    return .{ .done = .{} };
}

~hello()
| done |> _
```

### Example from `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_018_multiline_annotations/input.kz`
```koru

~import "$std/build"

// Flow call with annotation on separate line
~[default]
std.build:step(name: "compile") {
    zig build
}

// Flow call with compound annotation on separate line
~[default, depends_on("compile")]
std.build:step(name: "run") {
    ./zig-out/bin/main
}

// Event definition with annotation on separate line
~[comptime|norun]
pub event test.signal {
    value: i32
}

// Proc definition with annotation on separate line
~[raw]
proc test.handler {
    const x = 42;
}
```

### Example from `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_029_transform_requires_comptime/input.kz`
```koru

~[transform]event badTransform { count: i32 } -> (result: i32)

~proc badTransform {
    return .{ .result = count * 2 };
}
```

### Example from `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_032_implicit_source_param/input.kz`
```koru

~import "$std/io"

~[comptime|transform]event capture.source {
    source: Source,
    item: *const Item
}
| transformed { item: Item }

~proc capture.source {
    // For MVP: Just return the item unchanged to prove transform machinery works
    // TODO: Actually transform the source into inline code
    return .{ .transformed = .{ .item = item.* } };
}

// Use explicit source parameter
// The transform replaces this entire flow with a new AST node
~capture.source {
    const x = 42;
    const y = x + 1;
}
| transformed _ |> _
```

## Taps and Observation

### Example from `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_017_catchall_end_to_end/input.kz`
```koru

// Event with one required branch and two optional branches
~event process { value: u32 }
| success { result: u32 }
| ?warning { msg: []const u8 }
| ?info { details: []const u8 }

// Test: Handle only required branch, catch-all for optional branches
~process(value: 42)
| success _ |> _
|? |> _
```

### Example from `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_011_optional_branch_catchall/input.kz`
```koru

// Event with required and optional branches
~event process { value: u32 }
| success { result: u32 }        // Required
| ?warning { msg: []const u8 }   // Optional
| ?debug { details: []const u8 } // Optional

// Test 1: Simple |? discard
~process(value: 10)
| success |> _
|? |> _

// Test 2: |? with Transition metatype binding
~process(value: 20)
| success |> _
|? Transition |> _

// Test 3: |? with Profile metatype binding
~process(value: 30)
| success |> _
|? Profile |> _

// Test 4: Mix explicit optional handling + catch-all
~process(value: 40)
| success |> _
| warning |> _  // Explicit handling of optional branch
|? |> _           // Catches remaining optional branches (debug)

// Test 5: |? catches ALL unhandled optional branches
~process(value: 50)
| success |> _
|? Transition |> _  // Catches both warning and debug
```

### Example from `tests/regression/300_ADVANCED_FEATURES/330_PHANTOM_TYPES/330_031_tap_binding_substitution/input.kz`
```koru

~import "$std/taps"
~import "$app/fs"

// Tap that USES the binding to access file data
// This should work: the tap reads f.file.handle and passes it to log_open
~tap(app.fs:open -> *)
| opened f |> app.fs:log_open(handle: f.file.handle)
    | done |> _

// Main flow with auto-discharge
~app.fs:open(path: "test.txt")
| opened _ |> _
```

### Example from `tests/regression/300_ADVANCED_FEATURES/330_PHANTOM_TYPES/330_030_taps_with_auto_discharge/input.kz`
```koru

~import "$std/taps"
~import "$app/fs"

// Tap that observes file opens (no binding access, just observation)
~tap(app.fs:open -> *)
| opened |> app.fs:log_open(handle: 42)
    | done |> _

// Main flow: open a file and discard with auto-discharge
// The tap fires first, then auto-discharge inserts close()
~app.fs:open(path: "test.txt")
| opened _ |> _
```

### Example from `tests/regression/300_ADVANCED_FEATURES/330_PHANTOM_TYPES/330_042_metatype_binding_scope/input.kz`
```koru

~import "$std/taps"
~import "$std/io"

~event work {}
| done {}

~proc work {
    return .{ .done = .{} };
}

// This should work - 'p' binding should be in scope for string interpolation
~tap(work -> *)
| Profile p |> std.io:print.ln("Profile: {{p.source:s}}.{{p.branch:s}}")

~work()
| done |> _
```

### Example from `tests/regression/300_ADVANCED_FEATURES/310_COMPTIME/310_044_metatype_multiple_observers/input.kz`
```koru

~import "$std/taps"

~event hello { }
| done { }

~event logger { msg: []const u8 }
| done { }

~[pure]proc hello {
    return .{ .done = .{} };
}

~[pure]proc logger {
    return .{ .done = .{} };
}

// Observe with both Profile and Transition on same event
// Both metatype handlers should fire - note multiple branch handlers in one tap()
~tap(hello -> *)
| Profile p |> logger(msg: p.source)
    | done |> _
| Profile p2 |> logger(msg: p2.source)
    | done |> _

~hello()
| done |> _
```

## Verified Diagnostics (from SUCCESS tests with expected.txt)

- error[PARSE004]: unmatched '{' in branch payload shape
- error[PARSE003]: field name cannot start with a digit
- error[PARSE003]: Unknown type 'string'. In Zig/Koru, use '[]const u8' for strings
- error[PARSE003]: event declaration missing name
- error[PARSE004]: unmatched '{' in event shape
- error[PARSE003]: field missing type annotation
- error[PARSE003]: Flows terminate with '_', not 'return'
- error[PARSE003]: invalid branch name '' - must be a valid identifier
- error[PARSE003]: duplicate branch name 'done'
- error[PARSE003]: import paths must start with $ alias (e.g., '$std/io', '$src/helper') - define aliases in koru.json
- error[PARSE003]: 'pub' is not valid on proc declarations - only events can be public
- error[PARSE003]: invalid branch name '| done' - must be a valid identifier
