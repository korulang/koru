# Build System Design: Top-Level Comptime Execution

Test 619 demonstrates Koru's **top-level comptime execution** architecture - the build system is implemented IN Koru using the same execution model as runtime code.

## Overview

Unlike traditional build systems (Make, CMake, etc.), Koru's build system:
- ✅ Is written in Koru itself
- ✅ Uses top-level comptime calls (parallel to runtime → main)
- ✅ Executes automatically on import (zero boilerplate)
- ✅ Can be opted out with compiler flags

## Architecture Principles

### 1. Implicit Source Blocks

Just like FlowAST has implicit `{ flow }` syntax:
```koru
~std.threading:spawn { ~work() | done |> _ }
```

Source type has implicit `{ zig_code }` syntax:
```koru
~std.build:requires {
    exe.linkSystemLibrary("sqlite3");
}
```

The `{ }` block is compiled to a `Source` parameter containing raw Zig code.

### 2. Top-Level Comptime Execution (Parallel to Runtime)

Just like top-level runtime flows are collected into `main()`:
```koru
~hello()  // Top-level runtime call
| done |> _
```

Top-level comptime flows execute during compilation:
```koru
~[comptime]build:collect(path: "build.zig")  // Executes during compilation
```

**The compiler treats them symmetrically:**
- Runtime top-level calls → collected into `main()`
- Comptime top-level calls → executed during compilation

**No specialized AST walkers needed!** Just execute top-level comptime calls when encountered.

### 3. Automatic Collection via Top-Level Calls

**In koru_std/build.kz:**
```koru
~[comptime]

var build_requirements: std.ArrayList([]const u8) = undefined;

~pub event requires { source: Source }
~proc requires {
    // Validate and return for collection
    if (valid(source)) {
        return .{ .added = .{ source = source } };
    }
}

~pub event collect { ctx: CompilerContext, ast: ProgramAST }
~proc collect {
    // ctx and ast are explicitly declared, compiler provides them
    ctx.begin_pass("collect_build_requirements");

    // Walk AST, find all build:requires calls
    for (ast.items) |item| {
        if (item.event == "std.build:requires") {
            // Extract Source parameter from AST node
            const source = item.params.source;

            // Call handler directly - it's just a function!
            const result = requires_event.handler(.{ .source = source });

            // Handle results
            if (result.added) {
                build_requirements.append(source);
            } else if (result.parse_error) {
                // Report error through CompilerContext
                ctx.error(
                    message: result.parse_error.msg,
                    location: item.source_location
                );

                // Continue collecting to find all errors
                if (!ctx.should_abort()) {
                    continue;
                } else {
                    break;
                }
            }
        }
    }

    // Write build.zig with collected requirements
    ctx.info(message: std.fmt.format(
        "Writing build.zig with {} requirements",
        .{build_requirements.items.len}
    ));
    write_build_zig(path, build_requirements);

    ctx.end_pass("collect_build_requirements");
}

// Top-level call - executes automatically during compilation!
~[comptime(optional)]collect(path: "build.zig")
```

### 4. Execution Flow

**In user code:**
```koru
~[comptime]import "$std/build"

~[comptime]build:requires {
    exe.linkSystemLibrary("sqlite3");
}
```

**What happens:**

1. **Import** - Build module's AST is added to program (including top-level collect call)
2. **Compilation** - Compiler executes all top-level `~[comptime]` calls
3. **collect() runs** - Walks AST, finds all `build:requires`, executes them, writes build.zig
4. **Done** - build.zig generated automatically!

## Complete Flow

**User writes:**
```koru
~[comptime]import "$std/build"

~[comptime]build:requires {
    exe.linkSystemLibrary("sqlite3");
}

~[comptime]build:requires {
    exe.linkSystemLibrary("zlib");
}
```

**Compiler execution:**

**Step 1: Parse & Import**
- Parse user file
- Process `~[comptime]import "$std/build"`
- Load build.kz's AST (including its top-level `~[comptime(optional)]collect(...)`)
- Add to program AST

**Step 2: Execute Top-Level Comptime Calls**
- Find all top-level `~[comptime]` flows
- Execute build:collect(path: "build.zig")

**Step 3: Inside collect()**
- Walk ProgramAST
- Find all `build:requires` nodes
- Extract Source parameter from AST node
- Call handler directly: `const result = requires_event.handler(.{ .source = extracted_source })`
- Collect results into global list
- Write build.zig with all collected requirements

**Step 4: Test Validation**
- Verifies build.zig contains all three requirements
- Runs `zig build` to ensure it compiles
- Runs the binary to ensure it works

## Why This Design?

### Zero Boilerplate
User just imports and declares requirements:
```koru
~[comptime]import "$std/build"
~[comptime]build:requires { exe.linkSystemLibrary("sqlite3"); }
```

No manual collection call! The top-level `collect()` in build.kz handles everything.

### Parallel to Runtime
Runtime and comptime use the **same execution model**:
- Runtime: Top-level calls → `main()`
- Comptime: Top-level calls → execute during compilation

This makes comptime **easy to reason about** - it's just Koru code that runs earlier!

### User Control
Module authors control collection timing and behavior:
- Define what data to collect
- Define when/how to process it
- Write it in pure Koru (no compiler hacking)

### Opt-Out Capability
Don't want automatic build.zig generation?
```bash
koruc input.kz --disable=std.build:collect
```

The `~[comptime(optional)]` annotation makes it configurable.

## Comparison to Traditional Build Systems

**CMake/Make:**
```cmake
# Separate language, separate execution
target_link_libraries(myapp sqlite3)
```

**Koru:**
```koru
# Same language, executed during compilation
~std.build:requires {
    exe.linkSystemLibrary("sqlite3");
}
```

The build system IS the compilation process!

## Other Use Cases

This same pattern enables many compile-time features:

**Custom Optimizers:**
```koru
// In $compiler/optimize_hard.kz
~[comptime]
~compiler.inline()
~compiler.fuse()

// User code
~[production]import "$compiler/optimize_hard"
// Optimizations run automatically on import!
```

**Feature Configuration:**
```koru
// Top-level comptime call in feature module
~[comptime(optional)]features:configure(profile: "production")
```

**Code Generation:**
```koru
// Generate boilerplate at compile-time
~[comptime]codegen:derive_serialization(types: all_structs)
```

All use the **same top-level execution pattern**!

## Opting Out

The `~[comptime(optional)]` annotation controls **automatic execution**, not availability.

### What --disable Does

```bash
koruc input.kz --disable=std.build:collect
```

**Does NOT:**
- ❌ Remove `collect` event from AST
- ❌ Remove `collect` proc from compiled code
- ❌ Prevent manual calls to `collect`

**DOES:**
- ✅ Skip automatic execution during top-level comptime walk
- ✅ Allow user code to call it manually with custom parameters

### Custom Orchestration Example

```koru
~[comptime]import "$std/build"

~[comptime]event custom_build {}
~[comptime]proc custom_build {
    // Manually call collect with custom path
    ~std.build:collect(path: "my_custom_build.zig")
    | done |> _

    // Can call it multiple times!
    ~std.build:collect(path: "build.debug.zig")
    | done |> _
}

~[comptime]custom_build()
```

**Run with:**
```bash
koruc input.kz --disable=std.build:collect
```

The automatic collection is skipped, but `custom_build()` can still invoke it manually. This enables **composability** - users build on top of standard modules rather than replacing them.

## Implementation Status

- ✅ Implicit Source block syntax (specified in SPEC.md)
- ❌ Top-level comptime execution (needs implementation)
- ❌ `~[comptime(optional)]` annotation (needs implementation)
- ❌ `--disable` flag support (needs implementation)
- ❌ ProgramAST injection into comptime handlers (needs implementation)
- ❌ CompilerContext (ctx) injection for error reporting and metrics (needs implementation)

This test **documents the intended architecture** before implementation.

**See also:** [630_compiler_context](../630_compiler_context/) - Documents the CompilerContext API for error reporting, metrics, and pass tracking.

## Implementation Notes

The implementation is straightforward because **all handlers are just functions**:

```zig
// Generated handlers (already exists!)
pub const requires_event = struct {
    pub fn handler(input: Input) Output { ... }
};
```

### Explicit Declaration, Compiler Provision

Comptime handlers **explicitly declare** which compiler-provided parameters they need:
- **`ast: ProgramAST`** - Complete program AST for walking/inspection
- **`ctx: CompilerContext`** - Error reporting, metrics, pass tracking

User declares what they need:
```koru
~pub event collect { ctx: CompilerContext, ast: ProgramAST }
~proc collect { ... }
```

Compiler provides those parameters when calling:
```koru
collect(ctx: compiler_context, ast: program_ast)
```

**Only get what you ask for** - explicit, clear, extensible.

### Handler Calling Pattern

The `collect()` proc just needs to:
1. Walk AST (`ast.items`)
2. Match nodes by event name
3. Extract parameters from AST nodes
4. Call `handler(.{ params })` directly
5. Process results (check branches, report errors via `ctx`)
6. Track passes with `ctx.begin_pass()` / `ctx.end_pass()`

No special calling conventions, no thunking - just normal function calls with data from AST!

## Related Documentation

- [600_COMPTIME/SPEC.md](../SPEC.md) - Source type, FlowAST, comptime execution
- [050_PARSER/055_source_parameter_syntax](../../050_PARSER/055_source_parameter_syntax/) - Source type AST structure
- [koru_std/build.kz](../../../../koru_std/build.kz) - Build system implementation
