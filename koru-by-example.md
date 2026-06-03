# Koru by Example

> 22 hand-picked tests from `tests/regression/`. Generated 2026-06-02T20:26:39.162Z by `scripts/generate-corpus.js`.

Every example below is verbatim source from a passing POSITIVE regression test (negative MUST_FAIL tests are excluded — these are all what-to-do). Section prose is pulled from existing `SPEC.md` / `README.md` files in the relevant category directories — drift is tolerated in this pass and cleaned in a separate sweep. Per-test prose is intentionally NOT pulled; tests speak for themselves.

---

*Prose source: `tests/regression/SPEC.md` — may be drifted.*

## Koru Language Specification

> **Philosophy**: Documentation lives where it's tested. The regression tests cannot lie.

---

### Test Status

**Current status**: Run `./run_regression.sh --status` to see test results

The regression tests are the source of truth. They either compile and run, or they don't.

```bash
# See current test status (fast!)
./run_regression.sh --status

# Find regressions
./run_regression.sh --regressions

# Run specific test
./run_regression.sh 330_016

# Run a range (330-339)
./run_regression.sh 330

# Check specific test history
./run_regression.sh --history 123
```

---

### Directory Structure

```
tests/regression/
├── 000_CORE_LANGUAGE/          # Events, procs, flows, types
│   ├── 010_BASIC_SYNTAX/
│   ├── 020_EVENTS_FLOWS/
│   ├── 030_TYPES_VALUES/
│   └── 040_CONTROL_FLOW/
├── 100_MODULE_SYSTEM/          # Imports, namespaces, packages
│   ├── 110_IMPORTS/
│   ├── 120_NAMESPACES/
│   └── 130_PACKAGES/
├── 100_PARSER/                 # Parser features (identity branches, etc.)
├── 200_COMPILER_FEATURES/      # Parser, compilation, codegen, emitter
│   ├── 210_PARSER/
│   ├── 220_COMPILATION/
│   ├── 220_FLOW_CHECKER/
│   ├── 230_CODEGEN/
│   ├── 230_EMITTER/
│   ├── 240_STD_LIBRARY/
│   └── 260_SUBFLOW/
├── 200_SYNTAX/                 # Struct constructors
├── 300_ADVANCED_FEATURES/      # Comptime, phantom types, taps, etc.
│   ├── 310_COMPTIME/
│   ├── 320_STDLIB/
│   ├── 330_PHANTOM_TYPES/
│   ├── 340_FUSION/
│   ├── 340_TRANSFORMS/
│   ├── 350_SUBFLOWS/
│   ├── 355_OPTIONAL_BRANCHES/
│   ├── 360_TAPS_OBSERVERS/
│   ├── 365_INTERCEPTORS/       (design phase)
│   ├── 370_ACTORS/             (design phase)
│   ├── 380_TEMPLATING/
│   └── 390_KERNEL/
├── 320_CONTROL_FLOW/           # Expand, auto-thread pipeline
├── 400_RUNTIME_FEATURES/       # Purity, performance, budgeted interpreter
│   ├── 410_BUDGETED_INTERPRETER/
│   ├── 410_PURITY_CHECKING/
│   ├── 420_PERFORMANCE/
│   └── 430_RUNTIME/
├── 500_INTEGRATION_TESTING/    # Negative tests, bug reproductions, validation
│   ├── 510_NEGATIVE_TESTS/
│   ├── 520_BUG_REPRODUCTION/
│   └── 540_VALIDATION/
├── 600_STDLIB/                 # String, fmt
├── 700_EVENT_GLOBBING/         # Generics, glob patterns
├── 900_EXAMPLES_SHOWCASE/      # Hello world, language shootout, demos
│   ├── 910_LANGUAGE_SHOOTOUT/
│   └── 920_DEMO_APPLICATIONS/
└── tour/                       # Guided tour examples
```

---

### Specifications (SPEC.md files)

| Location | Topic | Status |
|----------|-------|--------|
| [000_CORE_LANGUAGE/SPEC.md](000_CORE_LANGUAGE/SPEC.md) | Events, procs, flows, type system | Needs path updates |
| [300_ADVANCED_FEATURES/310_COMPTIME/SPEC.md](300_ADVANCED_FEATURES/310_COMPTIME/SPEC.md) | Compile-time metaprogramming | Needs path updates |
| [300_ADVANCED_FEATURES/330_PHANTOM_TYPES/SPEC.md](300_ADVANCED_FEATURES/330_PHANTOM_TYPES/SPEC.md) | Phantom type states | Needs path updates |
| [300_ADVANCED_FEATURES/360_TAPS_OBSERVERS/SPEC.md](300_ADVANCED_FEATURES/360_TAPS_OBSERVERS/SPEC.md) | Event observation (`~tap()`) | Updated 2026-02-15 |
| [300_ADVANCED_FEATURES/365_INTERCEPTORS/SPEC.md](300_ADVANCED_FEATURES/365_INTERCEPTORS/SPEC.md) | Payload transformation | Design phase |
| [300_ADVANCED_FEATURES/370_ACTORS/SPEC.md](300_ADVANCED_FEATURES/370_ACTORS/SPEC.md) | Virtual actor system | Design phase |
| [300_ADVANCED_FEATURES/380_TEMPLATING/SPEC.md](300_ADVANCED_FEATURES/380_TEMPLATING/SPEC.md) | Liquid templates (`~emit`) | OK |
| [400_RUNTIME_FEATURES/410_BUDGETED_INTERPRETER/SPEC.md](400_RUNTIME_FEATURES/410_BUDGETED_INTERPRETER/SPEC.md) | Metered execution | Design phase |
| [400_RUNTIME_FEATURES/420_PERFORMANCE/SPEC.md](400_RUNTIME_FEATURES/420_PERFORMANCE/SPEC.md) | Optional branches, optimizations | Needs path updates |
| [500_INTEGRATION_TESTING/540_VALIDATION/SPEC.md](500_INTEGRATION_TESTING/540_VALIDATION/SPEC.md) | Branch coverage, phantom checking | Needs path updates |
| [900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT/SPEC.md](900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT/SPEC.md) | Benchmark methodology | OK |

> **WARNING**: Several SPEC.md files contain stale cross-references to old directory names.
> The tests themselves are the source of truth. When in doubt, read the test code.

---

### Quick Start

**New to Koru?** Start with the tests:

1. `000_CORE_LANGUAGE/010_BASIC_SYNTAX/` - Hello world, simple events
2. `100_MODULE_SYSTEM/110_IMPORTS/` - Multi-file programs
3. `300_ADVANCED_FEATURES/310_COMPTIME/` - Compile-time metaprogramming

**Looking for something specific?** Use `./run_regression.sh --status` or grep the test directories.

---

*The regression tests are the ultimate documentation - they cannot misrepresent reality.*

---

## Contents

- **CORE LANGUAGE / BASIC SYNTAX** — 3 tests
- **CORE LANGUAGE / EVENTS FLOWS** — 4 tests
- **CORE LANGUAGE / LITERALS** — 2 tests
- **CORE LANGUAGE / CONTROL FLOW** — 5 tests
- **ADVANCED FEATURES / COMPTIME** — 2 tests
- **ADVANCED FEATURES / PHANTOM TYPES** — 2 tests
- **RUNTIME FEATURES** — 2 tests
- **STDLIB / STRING** — 1 test
- **STDLIB / FMT** — 1 test

---

# CORE LANGUAGE

*Prose source: `tests/regression/000_CORE_LANGUAGE/SPEC.md` — may be drifted.*

## Core Language Specification

> The fundamentals - events, procs, flows, and types.

📚 **[Back to Main Spec Index](../../../SPEC.md)**

**Last Updated**: 2025-10-05
**Test Range**: 101-105

---

### File Structure

A `.kz` file is a **valid Zig file** with Koru extensions:
- Zig code is written normally
- Lines starting with `~` enter Koru parsing mode for that construct
- The compiler processes Koru constructs and generates Zig code

**Example**:
```koru
const std = @import("std");  // Regular Zig

~event greet { name: []const u8 }  // Koru construct
| greeting { message: []const u8 }

~proc greet {  // Koru proc
    return .{ .greeting = .{ .message = name } };
}
```

See: [101_hello_world](../101_hello_world/)

---

### Lexical Elements

#### The Tilde Marker (`~`)

The `~` marks Koru constructs at the top level:
- `~event` - Event declaration
- `~proc` - Proc implementation
- `~import` - Module import
- `~TAP` - Event tap attachment

**Inside flows**, no `~` is needed:
```koru
~greet(name: "World")      // Top-level: needs ~
| greeting g |> process()  // Inside flow: no ~ needed
```

#### Identifiers

Event names can use **dots** for namespacing:
```koru
~event file.read { path: []const u8 }
~event user.auth.login { username: []const u8, password: []const u8 }
```

Dots create nested structs in generated code:
```zig
pub const file = struct {
    pub const read = struct { /* ... */ };
};
```

#### Indentation

Koru uses **indentation** to determine flow boundaries:
- Each event invocation must handle all its branches
- Parser tracks branch coverage
- Indentation makes the code unambiguous (continuation branches can be created at comptime)

**Why**: Event branches can be generated at compile-time, so the parser can't statically know all possible continuations.

---

### Event Declaration

#### Basic Syntax

```koru
~[annotations]pub event name { input_fields }
| branch_name { output_fields }
| branch_name { output_fields }
```

**Private events** (omit `pub`):
```koru
~event name { input_fields }
| branch_name { output_fields }
```

**Annotations** are always optional (see [Taps & Observers](../500_TAPS_OBSERVERS/SPEC.md#annotations)).

#### Branch Order

Branch order is **semantically significant** - list hot paths first for optimization.

The compiler may use branch order to:
- Generate more efficient dispatch code
- Optimize for common cases
- Improve branch prediction

#### Void Events

Events can have **no output branches** (void events):
```koru
~event log { message: []const u8 }

~proc log {
    std.debug.print("{s}\n", .{message});
    // No return - void event
}
```

See: [105_void_event](../105_void_event/)

#### Field Types

Input and output fields use **Zig types**:
```koru
~event compute {
    x: i32,
    y: i32,
    options: struct { verbose: bool }
}
| result { sum: i32 }
```

---

### Proc Implementation

#### Zig Implementation

Procs are implemented in **pure Zig**:
```koru
~proc greet {
    // 'name' is automatically in scope from event input
    const message = try std.fmt.allocPrint(
        allocator,
        "Hello, {s}!",
        .{name}
    );
    return .{ .greeting = .{ .message = message } };
}
```

**Implicit bindings**:
- All event input fields are in scope
- Return value must be a branch constructor (`.{ .branch_name = .{ fields } }`)
- Void events don't need a return statement

See: [102_simple_event](../102_simple_event/)

#### Variable Scope

Input fields are automatically available:
```koru
~event process { value: u32, config: Config }
| success { result: u32 }

~proc process {
    // 'value' and 'config' are in scope
    const result = value * config.multiplier;
    return .{ .success = .{ .result = result } };
}
```

---

### Flow Invocation

#### Basic Invocation

```koru
~event_name(field: value, field2: value2)
| branch_name binding |> next_step()
| other_branch |> _  // Terminal
```

**Continuations** handle each branch:
- `binding` captures the branch payload
- `|> next_step()` pipes to next event
- `|> _` terminates (no further processing)

See: [103_simple_flow](../103_simple_flow/)

#### Multiple Flows

Multiple flows can invoke the same event:
```koru
~greet(name: "Alice")
| greeting g |> process(g.message)

~greet(name: "Bob")
| greeting g |> process(g.message)
```

See: [104_multiple_flows](../104_multiple_flows/)

---

### Type System

#### Base Types

Koru uses **Zig's type system**:
- Primitives: `u32`, `i32`, `f64`, `bool`, etc.
- Strings: `[]const u8`
- Structs: `struct { field: Type }`
- Unions: `union(enum) { variant: Type }`
- Pointers: `*Type`, `[]Type`

#### Branch Payloads

Branch outputs are **Zig structs**:
```koru
~event parse { input: []const u8 }
| success { ast: AST }
| error { message: []const u8, line: usize }
```

Generated:
```zig
pub const Output = union(enum) {
    success: struct { ast: AST },
    error: struct { message: []const u8, line: usize },
};
```

#### Phantom Types

Koru extends Zig with **phantom type states** for compile-time state tracking:
```koru
~event open { path: []const u8 }
| opened { file: *File[fs:open] }  // Phantom state: fs:open
```

See: [Validation - Phantom Types](../400_VALIDATION/SPEC.md#phantom-types)

---

### Execution Model

#### Event Dispatch

Events compile to **struct namespaces** with a `handler` function:
```zig
pub const greet = struct {
    pub const Input = struct { name: []const u8 };
    pub const Output = union(enum) {
        greeting: struct { message: []const u8 }
    };
    pub fn handler(e: Input) Output {
        // Proc implementation
    }
};
```

#### Flow Compilation

Flows compile to **Zig functions**:
```zig
pub fn flow0() void {
    const result = greet.handler(.{ .name = "World" });
    switch (result) {
        .greeting => |g| {
            // Continuation code
        },
    }
}
```

#### Main Entry

Generated `main()` calls all top-level flows:
```zig
pub fn main() void {
    main_module.flow0();
    main_module.flow1();
    // ...
}
```

---

### Verified By Tests

- [101_hello_world](../101_hello_world/) - Basic compilation
- [102_simple_event](../102_simple_event/) - Event + proc
- [103_simple_flow](../103_simple_flow/) - Flow invocation
- [104_multiple_flows](../104_multiple_flows/) - Multiple flows
- [105_void_event](../105_void_event/) - Void events

---

### Related Specifications

- [Control Flow](../100_CONTROL_FLOW/SPEC.md) - Branches, labels, continuations
- [Validation](../400_VALIDATION/SPEC.md) - Type checking, phantom types
- [Optimizations](../910_OPTIMIZATIONS/SPEC.md) - Optional branches

---

## BASIC SYNTAX

### 010_000_hello_world_koru

```koru
const name = "World";
const debug = true;
const count: i32 = 42;

// Hello World in pure Koru.
// This is the frontpage example from korulang.org.

~import "$std/io"

~std.io:print.blk {
    {% if debug %}[DEBUG] {% endif %}Hello, {{ name:s }}!
    The answer is {{ count:d }}.
}
```

**Output:**

```
[DEBUG] Hello, World!
The answer is 42.
```

### 010_001_hello_world

```koru
// ============================================================================
// VERIFIED REGRESSION TEST - DO NOT MODIFY WITHOUT DISCUSSION
// ============================================================================
// Test: Pure Zig code in a .kz file
// ============================================================================
const std = @import("std");

pub fn main() void {
    std.debug.print("Hello World\n", .{});
}
```

**Output:**

```
Hello World
```

### 010_002_simple_event

```koru
// Test 002: Event and host proc declaration without flow
// This should compile but not produce any output
// Prefer subflow implementations for ordinary Koru logic; this test only
// verifies the Zig host implementation boundary.
const std = @import("std");

~event hello {}

~proc hello|zig {
    std.debug.print("Event executed\n", .{});
}
```

## EVENTS FLOWS

### 020_001_simple_flow

```koru
// Test 003: Simple flow execution
// This should compile, run, and output "Flow executed"
const std = @import("std");

~event hello {}

~proc hello|zig {
    std.debug.print("Flow executed\n", .{});
}

// Top-level flow - should execute
~hello()
```

**Output:**

```
Flow executed
```

### 020_004_void_event

```koru
// ============================================================================
// VERIFIED REGRESSION TEST - DO NOT MODIFY WITHOUT DISCUSSION
// ============================================================================
// Test: Void events (no branches) in flows
// Search: parseVoidEvent void_event no_branches
// ============================================================================

const std = @import("std");

// Counter to verify void events actually execute
var setup_count: i32 = 0;
var cleanup_count: i32 = 0;
var process_count: i32 = 0;

// Void events have no output branches
~event setup {}

~proc setup|zig {
    setup_count += 1;
    std.debug.print("Setup: count={}\n", .{setup_count});
}

~event cleanup {}

~proc cleanup|zig {
    cleanup_count += 1;
    std.debug.print("Cleanup: count={}\n", .{cleanup_count});
}

~event process {}

~proc process|zig {
    process_count += 1;
    std.debug.print("Process: count={}\n", .{process_count});
}

// Test void events in flows
// Call setup once
~setup()

// Call process three times  
~process()
~process()
~process()

// Call cleanup once
~cleanup()

// Verify with a regular event
~event verify {}

~proc verify|zig {
    if (setup_count == 1 and process_count == 3 and cleanup_count == 1) {
        std.debug.print("Void events work correctly\n", .{});
    } else {
        std.debug.print("FAILED: setup={}, process={}, cleanup={}\n", .{setup_count, process_count, cleanup_count});
    }
}

~verify()
```

**Output:**

```
Setup: count=1
Process: count=1
Process: count=2
Process: count=3
Cleanup: count=1
Void events work correctly
```

### 020_005_void_event_chained

```koru
// ============================================================================
// VERIFIED REGRESSION TEST - DO NOT MODIFY WITHOUT DISCUSSION
// ============================================================================
// Test: Void events (no branches) in flows
// Search: parseVoidEvent void_event no_branches
// ============================================================================

const std = @import("std");

// Counter to verify void events actually execute
var setup_count: i32 = 0;
var cleanup_count: i32 = 0;
var process_count: i32 = 0;

// Void events have no output branches
~event setup {}

~proc setup|zig {
    setup_count += 1;
    std.debug.print("Setup: count={}\n", .{setup_count});
}

~event cleanup {}

~proc cleanup|zig {
    cleanup_count += 1;
    std.debug.print("Cleanup: count={}\n", .{cleanup_count});
}

~event process {}

~proc process|zig {
    process_count += 1;
    std.debug.print("Process: count={}\n", .{process_count});
}

// Test void events in flows
// Call setup once
~setup()

// Call process three times  
~process()
~process() |> process()

// Call cleanup once
~cleanup()

// Verify with a regular event
~event verify {}

~proc verify|zig {
    if (setup_count == 1 and process_count == 3 and cleanup_count == 1) {
        std.debug.print("Void events work correctly\n", .{});
    } else {
        std.debug.print("FAILED: setup={}, process={}, cleanup={}\n", .{setup_count, process_count, cleanup_count});
    }
}

~verify()
```

**Output:**

```
Setup: count=1
Process: count=1
Process: count=2
Process: count=3
Cleanup: count=1
Void events work correctly
```

### 020_014_pure_subflow_impl

```koru
// Test: Pure subflow implementation (no proc needed)
// From the README example - this is idiomatic Koru
// This is the default authoring model for ordinary event behavior.
~import "$std/io"

~event greet { name: []const u8 }
| greeting []const u8

~greet = greeting "Hello, " ++ name ++ "!"

~greet ("World")
| greeting msg |> std.io:print.ln(msg)
```

**Output:**

```
Hello, World!
```

## LITERALS

*Prose source: `tests/regression/000_CORE_LANGUAGE/030_LITERALS/README.md` — may be drifted.*

## 810s: Expression Syntax

Tests for expression-based flow syntax (design under review).

**Range**: 810-819

### What goes here
- If expressions in flows
- While loops in flows
- Expression composition
- Inline flow expressions

### Core Concepts: Shape Checking
A **shape** in Koru is the structure of data flowing through events. The shape checking system ensures:
1. **Exhaustiveness**: Event continuations must cover all branches.
2. **Structural Equality**: Shapes must match exactly at each pipeline step.
3. **Return Validation**: Proc returns must align with event declarations.

The **Union Collector** builds these shapes from branch constructors: `done { result: x + y }`.
The **Shape Checker** validates the structural correctness before code emission.

### Status
⚠️ Many tests in this range are SKIPPED - expression syntax is under design review.

### Examples
- `810_expression_if` - If/else in flow context
- `811_expression_expr` - General expression handling
- `812_expression_while` - While loops in flows

---

### 030_010_array_literal_simple

```koru
// TEST: Simple array literal syntax in flow arguments
//
// Koru should support clean array literal syntax: [a, b, c]
// The compiler infers the element type from the parameter type.
//
// Expected: Compiles and runs, passing array to the event

const std = @import("std");

~event sum { numbers: []const i32 }
| result i32

~proc sum|zig {
    var total: i32 = 0;
    for (numbers) |n| {
        total += n;
    }
    return .{ .result = total };
}

~event check { expected: i32, actual: i32 }

~proc check|zig {
    if (expected != actual) {
        std.debug.print("FAIL: expected {}, got {}\n", .{ expected, actual });
        std.process.exit(1);
    }
    std.debug.print("PASS: {} == {}\n", .{ expected, actual });
}

// Use array literal syntax
~sum(numbers: [1, 2, 3, 4])
| result r |> check(expected: 10, actual: r)
```

### 030_012_struct_literal_inline

```koru
// TEST: Inline struct literal in flow arguments
//
// Koru should support clean struct literal syntax: { field: value }
// This matches existing Koru patterns in subflows and branch constructors.
//
// Expected: Compiles and runs, struct passed to event

const std = @import("std");

pub const Config = struct {
    timeout: i32,
    retries: i32,
};

~event configure { config: Config }
| configured i32

~proc configure|zig {
    const total = config.timeout * config.retries;
    return .{ .configured = total };
}

~event check { expected: i32, actual: i32 }

~proc check|zig {
    if (expected != actual) {
        std.debug.print("FAIL: expected {}, got {}\n", .{ expected, actual });
        std.process.exit(1);
    }
    std.debug.print("PASS: {} == {}\n", .{ expected, actual });
}

// Use struct literal syntax (Koru-style, not Zig-style)
~configure(config: { timeout: 30, retries: 3 })
| configured c |> check(expected: 90, actual: c)
```

## CONTROL FLOW

### 201_multiple_branches

```koru
// ============================================================================
// VERIFIED REGRESSION TEST - DO NOT MODIFY WITHOUT DISCUSSION
// ============================================================================
// Test 007: Multiple branches in events
// Tests that events can have multiple branches and procs can return different ones
const std = @import("std");

~event check { value: i32 }
| positive i32
| zero
| negative i32

~proc check|zig {
    if (value > 0) return .{ .positive = value };
    if (value < 0) return .{ .negative = value };
    return .{ .zero = .{} };
}

~event handle_positive { n: i32 }

~proc handle_positive|zig {
    std.debug.print("Positive branch works: {}\n", .{n});
}

~event handle_zero {}

~proc handle_zero|zig {
    std.debug.print("Zero branch works\n", .{});
}

~event handle_negative { n: i32 }

~proc handle_negative|zig {
    std.debug.print("Negative branch works: {}\n", .{n});
}

// Test 1: Positive value (42)
~check(value: 42)
| positive p |> handle_positive(n: p)
| zero |> handle_zero()
| negative n |> handle_negative(n)

// Test 2: Zero value (0)
~check(value: 0)
| positive p |> handle_positive(n: p)
| zero |> handle_zero()
| negative n |> handle_negative(n)

// Test 3: Negative value (-7)
~check(value: -7)
| positive p |> handle_positive(n: p)
| zero |> handle_zero()
| negative n |> handle_negative(n)
```

**Output:**

```
Positive branch works: 42
Zero branch works
Negative branch works: -7
```

### 209_branching_flow

```koru
// ============================================================================
// VERIFIED REGRESSION TEST - DO NOT MODIFY WITHOUT DISCUSSION
// ============================================================================
// Test 209: Flow with multiple continuation branches
// A synthetic example for visualizing flows where multiple branches continue
// ============================================================================

const std = @import("std");

// Validation events
~event validate { value: i32 }
| valid i32
| invalid []const u8

~proc validate|zig {
    if (value > 0) {
        return .{ .valid = value };
    }
    return .{ .invalid = "Value must be positive" };
}

~event double { value: i32 }
| ok i32

~proc double|zig {
    return .{ .ok = value * 2 };
}

~event triple { value: i32 }
| ok i32

~proc triple|zig {
    return .{ .ok = value * 3 };
}

~event success { result: i32 }

~proc success|zig {
    std.debug.print("Success: {}\n", .{result});
}

~event failure { msg: []const u8 }

~proc failure|zig {
    std.debug.print("Failure: {s}\n", .{msg});
}

// Flow with multiple branching paths
~validate(value: 42)
| valid v |> double(value: v)
    | ok doubled |> success(result: doubled)
| invalid e |> triple(value: -1)
    | ok _ |> failure(msg: e)
```

### 233_empty_payload_branches

```koru
// Test: Multiple branches with BOTH having empty payloads
// This tests switch emission for empty union variants
// Previously: emitter would generate |name| capture even for empty payloads
// Fixed: emitter now generates => { without capture for empty payloads

~import "$std/io"

// Event with two branches, BOTH empty (no payload fields)
~event check_value { n: i32 }
| positive
| non_positive

~proc check_value|zig {
    if (n > 0) {
        return .{ .positive = .{} };
    } else {
        return .{ .non_positive = .{} };
    }
}

// Test: handle both empty branches
~check_value(n: 42)
    | positive |> std.io:println(text: "42 is positive")
    | non_positive |> std.io:println(text: "42 is not positive")

~check_value(n: -5)
    | positive |> std.io:println(text: "-5 is positive")
    | non_positive |> std.io:println(text: "-5 is not positive")

~check_value(n: 0)
    | positive |> std.io:println(text: "0 is positive")
    | non_positive |> std.io:println(text: "0 is not positive")
```

**Output:**

```
42 is positive
-5 is not positive
0 is not positive
```

### 240_subflow_defines_semantics

```koru
// Test 240: subflows define branch semantics
//
// Branch names in Koru are inert identifiers. Their meaning — what
// "return", "break", "continue", "ok", "north", or any other name
// signifies — is defined by the SUBFLOWS that resolve them, not by
// the compiler. This is the structural advantage over languages that
// bake fixed semantics for certain names into their grammar.
//
// This test deliberately uses names that ARE keywords in other
// languages (return, break, continue), to verify that the parser
// carries no value judgment about them. If a "common mistakes from
// other languages" trap is re-introduced at parser.zig parseStep,
// this test fails. That is the point.

~import "$std/io"

// Lower-level event: arbitrary outcome names
~pub event step {}
| return
| break
| continue

~step = continue

// Outer event: its own outcome vocabulary
~pub event run {}
| stopped
| iterated

// Subflow: `run` is satisfied by `step`, with `step`'s outcomes
// mapped to `run`'s. The meaning of `return`, `break`, `continue`
// lives HERE — in user code, not in the compiler.
~run = step()
| return |> stopped
| break |> stopped
| continue |> iterated

~std.io:print.ln("Testing subflow-defined semantics:")
~run()
| stopped |> std.io:print.ln("  stopped")
| iterated |> std.io:print.ln("  iterated")
```

**Output:**

```
Testing subflow-defined semantics:
  iterated
```

### 208_simple_server_flow

```koru
// ============================================================================
// VERIFIED REGRESSION TEST - DO NOT MODIFY WITHOUT DISCUSSION
// ============================================================================
// Test 208: Simple server-style flow with nested labels
// A simplified synthetic example inspired by tcp-echo for flow visualization
// ============================================================================

const std = @import("std");

// Server events
~event listen { port: u16 }
| ready u32
| failed []const u8

~proc listen|zig {
    std.debug.print("Listening on port {}\n", .{port});
    if (port == 0) {
        return .{ .failed = "Invalid port" };
    }
    return .{ .ready = port };
}

~event accept { server: u32 }
| connected { conn: u32, server: u32 }
| failed u32

~proc accept|zig {
    std.debug.print("Accepting connection\n", .{});
    if (server == 9999) {
        return .{ .failed = server };
    }
    return .{ .connected = .{ .conn = server + 1, .server = server } };
}

~event process { conn: u32 }
| done u32
| retry u32
| error { conn: u32, msg: []const u8 }

~proc process|zig {
    std.debug.print("Processing connection {}\n", .{conn});
    if (conn % 3 == 0) {
        return .{ .error = .{ .conn = conn, .msg = "Processing error" } };
    }
    if (conn % 2 == 0) {
        return .{ .done = conn };
    }
    return .{ .retry = conn };
}

~event close { conn: u32 }

~proc close|zig {
    std.debug.print("Closed connection {}\n", .{conn});
}

~event log_error { conn: u32, msg: []const u8 }
| logged u32

~proc log_error|zig {
    std.debug.print("Error on connection {}: {s}\n", .{conn, msg});
    return .{ .logged = conn };
}

~event cleanup { conn: u32 }

~proc cleanup|zig {
    std.debug.print("Cleaning up connection {}\n", .{conn});
}

// Main flow with nested labels
~listen(port: 8080)
| ready s |> #accept_loop accept(server: s)
    | connected c |> #process_loop process(c.conn)
        | done d |> close(conn: d) |> @accept_loop(c.server)
        | retry r |> @process_loop(conn: r)
        | error e |> log_error(e.conn, e.msg)
            | logged l |> cleanup(conn: l) |> @accept_loop(c.server)
    | failed f |> @accept_loop(server: f)
| failed _ |> _
```

# ADVANCED FEATURES

*Prose source: `tests/regression/300_ADVANCED_FEATURES/README.md` — may be drifted.*

## 300: Advanced Features

This category covers high-level abstractions like Subflows, Comptime integration, and the Kernel DSL.

### The Fractal Heart: Subflows
**Koru** means "coil" or "spiral," representing a fractal nature. The core abstraction is the **subflow**:
- A program is a subflow.
- Branch constructors are tiny, anonymous subflows.
- Everything follows the same pattern: **input → transformation → output**.

### Design Rule: Flows vs Procs
- **Flows do Plumbing**: Shape transformation and routing.
- **Procs do Computation**: Data transformation and logic.

Subflows enable complex composition while keeping the underlying Zig code readable and efficient.

---

## COMPTIME

*Prose source: `tests/regression/300_ADVANCED_FEATURES/310_COMPTIME/SPEC.md` — may be drifted.*

## Compile-Time Metaprogramming Specification

> FlowAST, ProgramAST, Expression - code generation and transformation at compile-time.

📚 **[Back to Main Spec Index](../../../SPEC.md)**

**Last Updated**: 2025-10-05
**Test Range**: 701-709

---

### Overview

Koru supports powerful compile-time metaprogramming through special types that allow code to manipulate and transform other code:

- **Expression** - Pass expressions as data for control flow and evaluation
- **FlowAST** - Pass flows as data for transformation
- **ProgramAST** - Access entire program for global transformations
- **Source** - Pass arbitrary syntax as data
- **File** - Compile-time file reading (not embedded)
- **EmbedFile** - Runtime file embedding (embedded in binary)

All special types enable compile-time processing in procs marked with `~[comptime]`.

---

### Expression Type

Pass expressions as compile-time data for control flow and computation.

#### Basic Syntax

```koru
~pub event if { expr: Expression }
| true {}
| ?false {}

~pub event expr { expr: Expression }
| result { value: <inferred_at_comptime> }
```

#### Expression Parameter Rules

1. **First positional implicit**: First `Expression` parameter can be positional (no name needed)
2. **Others must be named**: Additional `Expression` parameters must use `name: expr` syntax
3. **Proc-only invocation**: Events with `Expression` parameters can only be invoked from proc inline flows
4. **Comptime evaluation**: Expression AST passed to comptime proc for code generation

#### Usage Examples

**Conditional branching**:
```koru
~proc handle {
    // if - single implicit Expression
    ~if(age >= 18)
    | true |> serve_alcohol()
    | false |> serve_juice()
}
```

**Expression evaluation**:
```koru
~proc process {
    // expr - evaluate and branch on result
    ~expr(calculate_score(data))
    | result r when r.value > 100 |> excellent()
    | result r when r.value > 50 |> good()
    | result r |> needs_improvement()  // Catch-all required!
}
```

**Loop with condition**:
```koru
~pub event while { expr: Expression, max_iters: ?u32, flow: FlowAST }
| done {}

~proc loop {
    ~while(count < max, max_iters: 1000) {
        ~increment()
        | updated u |> count = u.value
    }
    | done |> finish()
}
```

#### Implementation

```koru
~[comptime]proc if {
    // At compile time:
    const expr_ast = expr;  // Expression parse tree

    // Emit: if (expr) { true_branch } else { false_branch }
    // Branches determined by continuations
}

~[comptime]proc expr {
    const expr_ast = expr;
    const return_type = inferType(expr_ast);  // Infer from context

    // Generate branch with inferred type
    // Emit evaluation code
}
```

#### Allowed Operations

- ✅ Field access: `obj.field`, `obj.nested.field`
- ✅ Comparisons: `==`, `!=`, `<`, `>`, `<=`, `>=`
- ✅ Logical: `&&`, `||`, `!`
- ✅ Literals: numbers, strings, booleans
- ✅ Arithmetic (in procs): `+`, `-`, `*`, `/`
- ❌ Function calls (in pure flows): `getValue()`

---

### FlowAST Type

Pass Koru flows as data for compile-time transformation.

#### Basic Syntax

```koru
~event transform { transform_flow: FlowAST }
| done { result: any }

~transform {
    transform_flow: {
        fetch(id: 123)
        | found f |> process(f.data)
        | missing |> use.default()
    }
}
| done d |> _
```

#### Implicit FlowAST Parameter

When an event has a `FlowAST` parameter, you can provide it implicitly using `{}` blocks:

```koru
// Event with flow parameter
~pub event optimize { cache_key: []const u8, flow: FlowAST }

// Implicit syntax - using {} directly after invocation
~optimize(cache_key: "v1") {
    ~fetch(id: 123)                // ~ marks each flow in the FlowAST
    | found f |> process(f.data)   // Must be exhaustive
    | missing |> use.default()      // Completes this flow

    ~validate(data)                 // New flow starts (also with ~)
    | valid v |> store(v)
    | invalid |> reject()
}
| optimized o |> log(o.stats)      // Outside {} = optimize's output branch
| unchanged |> use_original()
```

#### Key Rules for Implicit FlowAST

1. Use `{}` after the invocation to provide implicit FlowAST content
2. Each flow within the `{}` MUST start with `~` (just like top-level flows in a file)
3. Each flow must be exhaustive (all branches handled)
4. The `{}` creates a mini Koru environment where `~` marks flows
5. Continuations outside `{}` handle the event's output branches

#### Implementation

This enables transparent metaprogramming where the proc receives flows as data:

```koru
~proc optimize {
    comptime {
        const flows = flow;         // Array of flows from the FlowAST
        const key = cache_key;

        // Analyze and transform flows
        if (canOptimize(flows)) {
            // Generate optimized code with new branches
            return generateOptimized(flows);
        } else {
            // Generate unchanged branch
            return generatePassthrough(flows);
        }
    }
}
```

---

### ProgramAST Type

Access to the entire program's AST for global transformations.

#### Basic Syntax

```koru
~event global_optimizer { ast: ProgramAST }
| optimized { ast: ProgramAST }

~proc global_optimizer {
    comptime {
        var new_ast = ast;

        // Global dead code elimination
        new_ast = eliminateUnusedEvents(new_ast);

        // Cross-event inlining
        new_ast = inlineAcrossEvents(new_ast);

        // Whole-program optimization
        new_ast = optimizeGlobally(new_ast);

        return .{ .optimized = .{ .ast = new_ast } };
    }
}
```

#### With FlowAST

Events can accept both `FlowAST` and `ProgramAST` parameters:

```koru
// Event with both FlowAST and ProgramAST
~pub event optimize { flow: FlowAST, ast: ProgramAST }
| optimized { ast: ProgramAST }

// Usage - ProgramAST provided automatically
~optimize
| compute c |> process(c)         // Continuation → flow parameter
| done |> _                       // ProgramAST → current program

// The proc sees both the flow AND the entire program
~proc optimize {
    comptime {
        const flow_ast = flow;     // The continuation branches
        const program_ast = ast;   // The ENTIRE program!

        // Can analyze the local flow
        const patterns = analyzeFlow(flow_ast);

        // But transform the WHOLE program
        var new_ast = program_ast;
        new_ast = optimizeBasedOnPatterns(new_ast, patterns);

        return .{ .optimized = .{ .ast = new_ast } };
    }
}
```

#### Use Cases

ProgramAST enables:
- Cross-event optimization
- Global dead code elimination
- Whole-program transformations
- Domain-specific compilation strategies

#### Local Syntax, Global Effect

```koru
// Local invocation
~with_borrow_checking
| buffer b |> use(b)
| done |> _

// Global effect
~proc with_borrow_checking {
    comptime {
        // Add borrow checking to ALL buffers in the program!
        const new_ast = addGlobalBorrowChecking(ast, flow);
        return .{ .optimized = .{ .ast = new_ast } };
    }
}
```

---

### Source Type

Pass arbitrary syntax as data.

#### Syntax

```koru
~event query { sql: Source, params: []any }
| rows { data: []Row }

~query {
    sql: {
        SELECT * FROM users
        WHERE age > ? AND city = ?
    },
    params: .{21, "NYC"}
}
| rows r |> display(r.data)
```

Use for embedded DSLs, SQL queries, configuration syntax, etc.

#### Implicit Source Blocks

Like FlowAST, Source parameters can be provided implicitly using `{ }` blocks:

```koru
// Event with Source parameter
~pub event build_requires { source: Source }

// Implicit syntax - using {} directly
~build_requires {
    exe.linkSystemLibrary("sqlite3");
    exe.linkSystemLibrary("zlib");
}
```

The `{ }` block is compiled to a Source parameter containing the raw syntax.

---

### Top-Level Comptime Execution

Koru treats compile-time and runtime execution **symmetrically**:
- Runtime: Top-level calls collected into `main()`
- Comptime: Top-level calls executed during compilation

#### Execution Model

**Runtime example:**
```koru
~hello()  // Top-level call
| done |> ~goodbye()
    | done |> _
```
Compiler collects these into `main()` function.

**Comptime example:**
```koru
~[comptime]build:collect(path: "build.zig")  // Top-level call
```
Compiler executes this during compilation.

#### Automatic Execution on Import

Top-level comptime calls in imported modules execute automatically:

```koru
// In koru_std/build.kz
~[comptime]

~pub event collect { ast: ProgramAST }
~proc collect {
    // Walk AST, collect build requirements, write file
}

// Top-level call - executes when module is imported!
~[comptime(optional)]collect(path: "build.zig")
```

**User code:**
```koru
~[comptime]import "$std/build"  // This triggers collect()!

~[comptime]build:requires {
    exe.linkSystemLibrary("sqlite3");
}
```

#### Optional Execution

The `~[comptime(optional)]` annotation controls **automatic execution**, not availability.

**Default behavior:**
```koru
~[comptime(optional)]collect(path: "build.zig")
```
Executes automatically during compilation.

**With --disable flag:**
```bash
koruc input.kz --disable=std.build:collect
```

**What this does:**
- Skips automatic execution of this specific top-level call
- Event and proc remain in AST and compiled code
- User code can still call it manually

**Example - Custom orchestration:**
```koru
~[comptime]import "$std/build"

~[comptime]proc custom_build {
    // Manually invoke with custom parameters
    ~std.build:collect(path: "custom.zig")
    | done |> _
}

~[comptime]custom_build()
```

This enables **composability** - users can build on top of standard modules by disabling automatic behavior and orchestrating manually.

#### Compiler-Provided Parameters

Comptime events **explicitly declare** which compiler-provided parameters they need.

**User declares what they need:**
```koru
~[comptime]
~pub event collect { ctx: CompilerContext, ast: ProgramAST, path: []const u8 }
```

**Compiler provides declared parameters:**
- `CompilerContext` - Provided by compiler
- `ProgramAST` - Provided by compiler
- `path` - Provided by user at call site

**Call site:**
```koru
~[comptime]collect(path: "build.zig")
```

**Compiler execution:**
```koru
collect(ctx: compiler_context, ast: program_ast, path: "build.zig")
```

This is **explicit and extensible** - you only get what you ask for.

#### Complete Example: Build System

**In build.kz:**
```koru
~[comptime]

var requirements: std.ArrayList([]const u8) = undefined;

~pub event requires { source: Source }
~proc requires {
    // Validate and return for collection
    return .{ .added = .{ source = source } };
}

~pub event collect { ctx: CompilerContext, ast: ProgramAST }
~proc collect {
    // ctx and ast explicitly declared, compiler provides them
    ctx.begin_pass("collect_build_requirements");

    // Walk AST, find all build:requires
    for (ast.items) |item| {
        if (item.event == "std.build:requires") {
            // Extract Source parameter from AST node
            const source = item.params.source;

            // Call handler directly - it's just a function!
            const result = requires_event.handler(.{ .source = source });

            // Collect result
            if (result.added) {
                requirements.append(source);
            } else if (result.parse_error) {
                ctx.error(
                    message: result.parse_error.msg,
                    location: item.source_location
                );
            }
        }
    }

    ctx.end_pass("collect_build_requirements");
    write_build_zig(path, requirements);
}

// Executes automatically on import
~[comptime(optional)]collect(path: "build.zig")
```

**In user code:**
```koru
~[comptime]import "$std/build"  // Triggers collection

~[comptime]build:requires {
    exe.linkSystemLibrary("sqlite3");
}
```

#### Use Cases

This pattern enables:
- **Build systems** - collect dependencies, generate build files
- **Optimizers** - transform AST, apply optimizations
- **Code generators** - derive serialization, generate boilerplate
- **Feature flags** - configure compilation behavior

See: [619_build_requires_basic](../619_build_requires_basic/BUILD_SYSTEM_DESIGN.md)

---

### File vs EmbedFile

#### File (Compile-Time Only)

For compile-time file reading (contents NOT embedded in binary):

```koru
~event transpiler { source: File }
| transpiled { code: []const u8 }

~transpiler(source: "game.nes")
| transpiled t |> save(t.code)
```

The file is read during compilation but not embedded in the final binary.
Use for build-time operations, transpilation sources, configuration processing.

#### EmbedFile (Runtime Embedded)

For runtime file embedding (contents embedded in binary):

```koru
~event assets { icon: EmbedFile }
| loaded { data: []const u8 }

~assets(icon: "logo.png")
| loaded l |> display(l.data)
```

The file's contents are embedded in the binary and available at runtime.
Use for assets, default configs, templates needed when the program runs.

---

### Compile-Time Events

Events with `FlowAST` or `ProgramAST` parameters can generate their branches at compile-time:

```koru
// Branches not declared - generated by proc!
~event optimize { cache_key: []const u8, flow: FlowAST }

~proc optimize {
    comptime {
        // Analyze flow and generate appropriate branches
        if (canOptimize(flow)) {
            return generateBranches(&[_]Branch{
                .{ .name = "optimized", .payload = .{ .stats = Stats } },
                .{ .name = "unchanged" },
            });
        } else {
            return generateBranches(&[_]Branch{
                .{ .name = "failed", .payload = .{ .reason = []const u8 } },
            });
        }
    }
}
```

**Execution order**:
1. Input shape is declared normally
2. Output branches are generated by the proc's `comptime` block
3. Shape checking happens after compile-time execution
4. Continuations are parsed optimistically and validated later

---

### Host Type Injection

Events can request type information from the host environment:

```koru
~event get_platform {}
| platform { os: HostType, arch: HostType }

~proc get_platform {
    comptime {
        const os = @import("builtin").os.tag;
        const arch = @import("builtin").cpu.arch;
        // Return platform info as branch
    }
}
```

See: [701_host_type_injection](../701_host_type_injection/)

---

### Benchmark Type

Performance testing as a first-class language feature using FlowAST:

```koru
~pub event benchmark {
    name: []const u8,
    iterations: u32,
    flow: FlowAST,
    warmup_iterations: ?u32
}
| results {
    name: []const u8,
    comparisons: []Comparison
}

pub const Comparison = struct {
    label: []const u8,           // Event name
    avg_ns: u64,                 // Average nanoseconds per iteration
    median_ns: u64,              // Median time
    min_ns: u64,                 // Minimum time
    max_ns: u64,                 // Maximum time
    std_dev: f64,                // Standard deviation
    vs_baseline_percent: ?f64    // Percent vs first entry
};
```

**Usage**:
```koru
~benchmark(name: "Event Dispatch Overhead", iterations: 1_000_000) {
    ~calculate_pure()
    | done |> _

    ~calculate_events()
    | done |> _
}
| results r |> print_results(r)
| results r |> assert_overhead_under(r, max_percent: 5.0)
```

---

### Design Rationale

**Why special types?**
- Enable metaprogramming without runtime cost
- Keep syntax clean and familiar
- Make code generation explicit
- Allow domain-specific optimizations

**Why compile-time only?**
- Zero runtime overhead
- Statically analyzable
- Deterministic code generation
- No reflection needed

**Why ProgramAST in addition to FlowAST?**
- Enable whole-program optimizations
- Support cross-event transformations
- Allow global analysis
- Domain-specific compilation

---

### Verified By Tests

- [619_build_requires_basic](../619_build_requires_basic/) - Metacircular execution, implicit Source blocks, multi-pass architecture
- [701_host_type_injection](../701_host_type_injection/) - Host environment types

---

### Related Specifications

- [Core Language - Events](../000_CORE_LANGUAGE/SPEC.md#event-declaration) - Event basics
- [Core Language - Proc Implementation](../000_CORE_LANGUAGE/SPEC.md#proc-implementation) - Comptime procs
- [Validation - Shape Rules](../400_VALIDATION/SPEC.md#shape-rules) - Type checking
- [Control Flow - When Clauses](../100_CONTROL_FLOW/SPEC.md#when-clauses) - Expression evaluation

---

### 310_001_import_registers_taps

```koru
// Test 168: Import Registers Taps Automatically
//
// Tests that importing a module automatically registers any taps defined in it.
// This is the mechanism that makes `~[profile]import "$std/profiler"` work -
// the import adds the module's universal taps to the tap registry, enabling
// full-program instrumentation with a single line.
//
// Structure:
//   test_lib/
//     logger.kz  → Defines a universal tap ~tap(* -> *) that logs all events
//
// Expected: The logger's tap fires for ALL events, even though we didn't
//          explicitly write the tap pattern in this file.
//
// This demonstrates "ambient" behavior - importing makes taps active.

const std = @import("std");

// Import the logger module (which defines universal taps)
~import "$app/test_lib/logger"

// Define some events to test with
~event compute { x: i32 }
| result i32

~event format { value: i32 }
| formatted []const u8

~event display { text: []const u8 }

~proc compute|zig {
    std.debug.print("compute({d})\n", .{x});
    return .{ .result = x * 2 };
}

~proc format|zig {
    std.debug.print("format({d})\n", .{value});
    // Allocate temporary string for testing
    const text = "formatted";
    return .{ .formatted = text };
}

~proc display|zig {
    std.debug.print("Final: {s}\n", .{text});
}

// Call events - the logger's universal tap should intercept them!
~compute(x: 42)
| result r |> format(value: r)
    | formatted f |> display(text: f)
```

**Output:**

```
compute(42)
[TAP] Intercepted event: compute
format(84)
[TAP] Intercepted event: format
Final: formatted
```

### 310_005_annotation_inline_syntax

```koru
// Test 603: Inline Annotation Syntax
// Tests that ~[a|b|c] produces annotations: ["a", "b", "c"]

const std = @import("std");

// Single annotation
~[comptime] event single {}

// Multiple annotations with | delimiter
~[comptime|runtime] event dual {}

// Many annotations
~[comptime|runtime|fuseable|inline] event many {}

// Parameterized annotation (opaque string)
~[optimize(level: 3)] event optimized {}

// Mix of simple and parameterized
~[comptime|optimize(level: 3)|inline] event mixed {}

~proc single|zig { return .{ .done = .{} }; }
~proc dual|zig { return .{ .done = .{} }; }
~proc many|zig { return .{ .done = .{} }; }
~proc optimized|zig { return .{ .done = .{} }; }
~proc mixed|zig { return .{ .done = .{} }; }
```

## PHANTOM TYPES

*Prose source: `tests/regression/300_ADVANCED_FEATURES/330_PHANTOM_TYPES/SPEC.md` — may be drifted.*

## Phantom Types Specification

> Compile-time tracking of runtime states through opaque type annotations.

📚 **[Back to Main Spec Index](../../../SPEC.md)**

**Last Updated**: 2025-11-03
**Test Range**: 507-519, 909-920

---

### What Are Phantom Types?

**Phantom types** are compile-time annotations on types that track runtime states without affecting the actual type at runtime. They enable the compiler to enforce state machines, resource lifecycles, and other temporal properties.

```koru
~event open_file { path: []const u8 }
| opened { file: *File[fs:open!] }  // Phantom state: fs:open with cleanup required

~event close_file { file: *File[fs:open] }
| closed { file: *File[fs:closed] }

// This compiles:
~open_file(path: "test.txt")
| opened o |> close_file(file: o.file)
    | closed c |> _

// This fails at compile time:
~open_file(path: "test.txt")
| opened o |> close_file(file: o.file)
    | closed c |> close_file(file: c.file)  // ❌ Error: expects [fs:open], got [fs:closed]
```

---

### Phantom Type Syntax

#### Basic States

```koru
*Type[state]           // Simple state
*Type[module:state]    // Module-qualified state
*Type[module:state!]   // Cleanup-required state (! suffix)
```

#### State Variables (Generics)

```koru
*Type[M'owned|borrowed]    // State variable M constrained to owned OR borrowed
*Type[F'_]                 // State variable F with wildcard (any state)
```

#### Multiple States (Union Types)

```koru
*Type[open|closing]        // Accepts either state
```

---

### Phantom Type Semantics

Phantom types are **opaque strings** - their meaning is determined by the **semantic checker** you use. Different checkers can interpret phantom types differently!

#### 1. Semantic Checker (Default)

**Purpose**: Resource lifecycle tracking

**Identity Model**: `binding.field` names track resource identity through flows

**Key Features**:
- States transition through matching field names in event signatures
- Old bindings become invalidated when state changes
- Cleanup obligations (`!`) can be tracked (when implemented)

**Example**:
```koru
~event open { path: []const u8 }
| opened { file: *File[fs:open!] }

~event close { file: *File[fs:open] }
| closed { file: *File[fs:closed] }

// Identity tracking:
| opened f1 |>  // f1.file identity created with [fs:open!]
    close(f1.file)
    | closed c1 |>  // c1.file continues f1.file's identity, now [fs:closed]
        use(f1.file)  // ❌ SEMANTIC ERROR: f1.file invalidated, use c1.file
```

**Best For**:
- File handles
- Database connections
- GPU resources
- UI contexts
- Network sockets

See: [SEMANTIC.md](./SEMANTIC.md)

#### 2. Rust-Style Borrow Checker (Planned)

**Purpose**: Ownership and borrowing enforcement

**Identity Model**: Actual pointer/reference tracking with lifetime annotations

**Key Features**:
- Ownership transfer detection
- Mutable vs immutable borrows
- Lifetime scoping
- Prevents aliasing violations

**Syntax**:
```koru
~event process<'a> { data: *Data['a:owned] }
| done { data: *Data['a:moved] }

~event borrow<'a> { data: *Data['a:owned] }
| borrowed { data: *Data['a:borrowed], original: *Data['a:lent] }
```

**Best For**:
- Memory safety
- Preventing use-after-free
- Concurrent access control

See: [BORROW_CHECKING.md](./BORROW_CHECKING.md) (planned)

#### 3. ECS Component Tracking (Planned)

**Purpose**: Entity component system validation

**Identity Model**: Entity ID with component presence/absence tracking

**Key Features**:
- Component presence requirements
- Component addition/removal tracking
- System compatibility checking

**Syntax**:
```koru
~event render { entity: *Entity[has:transform+sprite+health] }
| rendered { entity: *Entity[has:transform+sprite+health] }

~event remove_sprite { entity: *Entity[has:sprite] }
| removed { entity: *Entity[lacks:sprite] }
```

**Best For**:
- Game engines
- Data-oriented designs
- Component systems

See: [ECS.md](./ECS.md) (planned)

#### 4. Custom Semantic Checkers

You can write your own phantom type checker as a compiler pass!

```koru
~event my_phantom_checker { ast: FlowAST }
| valid { ast: FlowAST }
| invalid { errors: []Error }

~proc my_phantom_checker {
    // Implement YOUR domain-specific phantom semantics
    // Examples:
    // - HTTP state machines (idle → sending → waiting → receiving)
    // - GPU pipeline states (uninitialized → compiled → bound → executing)
    // - Transaction states (open → dirty → committed/rolled_back)
    // - Authentication states (unauthenticated → authenticated → authorized)
}
```

---

### The Semantic Checker (Default)

The default phantom type checker uses **field name identity tracking**.

#### Identity Rule

Two bindings refer to the **same resource** if:
1. They have the same field name
2. One was derived from the other through event invocations

```koru
| opened f1 |>       // f1.file is identity "file-1"
    write(f1.file)
    | written w1 |>  // w1.file continues "file-1" (same field name "file")
        close(w1.file)
        | closed c1 |> // c1.file continues "file-1"
```

#### Invalidation Rule

When a phantom state changes:
- The old binding becomes **invalidated**
- Must use the new binding from the continuation

```koru
| opened f |>
    close(f.file)    // f.file consumed here
    | closed c |>
        read(f.file)  // ❌ ERROR: f.file invalidated
        read(c.file)  // ✅ OK: c.file is current binding
```

#### Multiple Resources

Different field names = different identities:

```koru
| opened o |>  // o.file1 and o.file2 are separate identities
    close(o.file1)
    | closed c |>
        read(o.file1)  // ❌ ERROR: file1 is closed
        read(o.file2)  // ✅ OK: file2 still open
```

---

### Cleanup Obligations (!)

The `!` marker provides compile-time enforcement of resource cleanup through two complementary syntaxes:

#### Producing Obligations: `[state!]`

The `!` suffix on a **return signature** marks states that **require cleanup** before going out of scope:

```koru
~event open { path: []const u8 }
| opened { file: *File[opened!] }  // ! produces cleanup obligation

~open(path: "test.txt")
| opened f |>
    _  // ❌ ERROR: f.file has cleanup obligation that must be satisfied!
```

#### Consuming Obligations: `[!state]`

The `!` prefix on a **parameter** marks events that **dispose** of resources:

```koru
~event close { file: *File[!opened] }  // ! consumes cleanup obligation
| closed {}

~open(path: "test.txt")
| opened f |> close(file: f.file)  // Obligation satisfied by disposal
    | closed |>
        _  // ✅ OK: f.file was properly cleaned up
```

#### Escaping Through Interfaces

Obligations can be **documented as escaping** through return signatures:

```koru
~event my_subflow {}
| file_opened { file: *File[opened!] }  // ! in return = documented escape

~proc my_subflow {
    ~open(path: "internal.txt")
    | opened f |> file_opened { file: f.file }
    // No error! Obligation escapes through signature
}

// Caller receives the obligation:
~my_subflow()
| file_opened f |> close(file: f.file)  // Caller's responsibility
    | closed |> _
```

#### Safety Model: Trust Library Authors, Verify Usage

Koru's cleanup obligation system follows a **pragmatic safety model**:

**The compiler CANNOT verify** that a disposal event (`[!state]`) actually cleans up the resource. This is the **library author's responsibility**:
```koru
~event file.close { file: *File[!opened] }
| closed {}

~proc close {
    // Library author's responsibility: actually close the file!
    c.fclose(file.handle);
    return .{ .closed = .{} };
}
```

**The compiler CAN verify** that library users properly handle cleanup obligations:
```koru
~open(path: "test.txt")
| opened f |>
    _  // ❌ Compile error: forgot to close

~open(path: "test.txt")
| opened f |> close(file: f.file)
    | closed |> _  // ✅ OK: properly cleaned up

~open(path: "test.txt")
| opened f |> close(file: f.file)
    | closed |> use_file(file: f.file)  // ❌ Error: use after disposal!
```

This is **lower safety than Rust** (which proves library correctness) but **higher safety than most languages** (which have no compile-time cleanup enforcement). The trade-off enables:
- C interop without lies
- Narrative engine flexibility
- Performance without runtime overhead
- Extensibility through custom compiler passes

**Best practice**: Library correctness is verified through testing. Usage correctness is verified by the compiler.

#### Cleanup Semantics: Bindings Persist

Unlike Rust, Koru bindings **do not move** when passed to events. They **persist** through nested continuations:

```koru
~open(path: "test.txt")
| opened f |> store(file: f.file)
    | stored |>
        use(file: f.file)  // ✅ OK: f.file is STILL accessible
        | used |> _  // ❌ ERROR: still has cleanup obligation!
```

Cleanup obligations are only satisfied when:
1. Resource passed to disposal event (`[!state]`), OR
2. Resource returned with `!` in continuation signature (documented escape)

After disposal, the binding becomes **poisoned** and cannot be used:
```koru
| opened f |> close(file: f.file)  // Disposes f.file
    | closed |>
        use(file: f.file)  // ❌ ERROR: f.file was disposed!
```

**Status**: Implementation in progress (tests 513-519)

See: [CLEANUP_SEMANTICS.md](./CLEANUP_SEMANTICS.md) for detailed examples

---

### Module-Qualified States

Phantom states can be qualified by module to avoid collisions:

```koru
*File[fs:open]         // Filesystem module's "open" state
*Buffer[gpu:allocated] // GPU module's "allocated" state
*Conn[http:idle]       // HTTP module's "idle" state
```

This allows different modules to use the same state names (`open`, `closed`) without conflict.

See: [507_module_qualified_phantom_states](../507_module_qualified_phantom_states/)

---

### Design Principles

#### 1. Phantom Types Are Optional

You can use Koru without phantom types! They're an **ergonomic aid**, not a requirement.

```koru
// Without phantom types - works fine
~event open {}
| opened { file: *File }

// With phantom types - compiler helps prevent mistakes
~event open {}
| opened { file: *File[fs:open!] }
```

#### 2. Phantom Semantics Are Pluggable

The meaning of phantom types is determined by the semantic checker, which is **user-replaceable**.

Don't like the default semantic checker? Write your own! Or use multiple checkers in your compilation pipeline.

#### 3. Zero Runtime Cost

Phantom types are **compile-time only**. They generate the same code as non-phantom types.

```koru
*File[fs:open]  // Compiles to: std.fs.File
```

The phantom annotation `[fs:open]` exists only during compilation.

---

### Verified By Tests

**Semantic Checker**:
- [909_phantom_state_mismatch](../909_phantom_state_mismatch/) - Detects incompatible states
- [910_phantom_state_valid](../910_phantom_state_valid/) - Accepts valid transitions
- [507_module_qualified_phantom_states](../507_module_qualified_phantom_states/) - Module-qualified states

**Cleanup Obligations**:
- [513_cleanup_obligation_escape](../513_cleanup_obligation_escape/) - Error on uncleaned resources at terminator
- [514_cleanup_obligation_satisfied](../514_cleanup_obligation_satisfied/) - Proper cleanup with `[!state]` disposal
- [515_cleanup_consumed_by_disposal](../515_cleanup_consumed_by_disposal/) - Disposal event consumes obligation
- [516_use_after_disposal](../516_use_after_disposal/) - Error on use after disposal
- [517_obligation_escapes_via_interface](../517_obligation_escapes_via_interface/) - Obligation transfers through return signature
- [518_obligation_lost_at_boundary](../518_obligation_lost_at_boundary/) - Error when obligation lost at flow boundary
- [519_multiple_cleanup_paths](../519_multiple_cleanup_paths/) - Multiple disposal events coexist

**Planned**:
- Identity tracking through field names
- Multiple resource tracking
- Borrow checking semantics
- ECS component semantics

---

### Related Specifications

- [Validation](../400_VALIDATION/SPEC.md) - Type checking, coverage checking
- [Compiler Architecture](../../../docs/architecture/COMPILER_ARCHITECTURE.md) - Semantic checker integration

---

*Phantom types: Making impossible states unrepresentable, one compile at a time.* ✨

---

### 330_005_cleanup_obligation_satisfied

```koru
~import "$app/fs"
~app.fs:open(path: "test.txt")
| opened f |> app.fs:close(file: f)
```

**Output:**

```
Opening file: test.txt
Closing file
```

### 330_006_cleanup_consumed_by_disposal

```koru
~import "$app/fs"
~app.fs:open(path: "test.txt")
| opened f |> app.fs:close(file: f)
```

**Output:**

```
Opening file: test.txt
Closing file
```

# RUNTIME FEATURES

### 400_060_fmt_blk_autodispose

```koru
// Test: Simple phantom obligations
//
// Tests that [allocated!] obligation can be discharged with [!allocated]

~import "$std/io"

const std = @import("std");

pub const Resource = struct {
    data: []const u8,
    allocator: std.mem.Allocator,
};

~pub event create_resource { name: []const u8 }
| created *Resource<allocated!>

~proc create_resource|zig {
    const alloc = std.heap.page_allocator;
    const data = std.fmt.allocPrint(alloc, "Resource: {s}", .{name}) catch unreachable;
    const res = alloc.create(Resource) catch unreachable;
    res.* = .{ .data = data, .allocator = alloc };
    return .{ .created = res };
}

~pub event destroy_resource { res: *Resource<!allocated> }

~proc destroy_resource|zig {
    res.allocator.free(res.data);
    std.heap.page_allocator.destroy(res);
}

// Simple sequential test
~std.io:print.ln("Test start")
~create_resource(name: "Test")
| created r |> destroy_resource(res: r) |> std.io:print.ln("Test done")
```

**Output:**

```
Test start
Test done
```

### 400_070_effect_branch_minimal

```koru
// Test: minimum effect-branch program — proc yields, consumer handles.
//
// `! pong []const u8` is an effect branch; the proc body calls `pong(msg)`
// which transfers control to the consumer's `! pong reply |> ...` handler,
// runs it, then returns. No terminal `|` branches — this is a void event
// with one effect operation.

~import "$std/io"

const std = @import("std");

~pub event ping { msg: []const u8 }
! pong []const u8

~proc ping|zig {
    pong(msg);
}

~ping(msg: "hello effect branches")
! pong reply |> std.io:print.blk {
    {{ reply:s }}
}
```

**Output:**

```
hello effect branches
```

# STDLIB

## STRING

### 610_001_string_basic

```koru
// Test: Basic string creation and read
~import "$std/string"
~import "$std/io"

~std.string:from_page(text: "hello")
| ok s |> std.string:read(s)
    | slice text |> std.io:print.ln("{{ text:s }}") |> std.string:free(s)
| err _ |> _
```

**Output:**

```
hello
```

## FMT

### 620_001_fmt_ln_basic

```koru
// TEST: fmt:ln basic - format a string and get it back via | line continuation
~import "$std/fmt"
~import "$std/io"

~event greet { name: []const u8 }
| greeted []const u8

~greet = std.fmt:ln("Hello, {{ name:s }}!")
| line l |> greeted l.text

~greet(name: "World")
| greeted g |> std.io:println(text: g)
```

**Output:**

```
Hello, World!
```

